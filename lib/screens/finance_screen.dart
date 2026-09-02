import 'package:flutter/material.dart';

import '../design/neon_tokens.dart';
import '../design/neon_widgets.dart';
import '../features/assistant/state/assistant_engine.dart';
import '../services/api_service.dart';
import '../services/assistant_identity.dart';

/// FINANCE SECTION — the user's money map: expected incomes, EMIs (with
/// interest and outstanding principal) and recurring expenses. Everything
/// here is also voice-editable ("I have a bike EMI of 3500 at 11%"), and
/// the "Plan with Hari" button hands the ledger to the assistant for a
/// concrete highest-interest-first plan.
class FinanceScreen extends StatefulWidget {
  const FinanceScreen({super.key});

  @override
  State<FinanceScreen> createState() => _FinanceScreenState();
}

class _FinanceScreenState extends State<FinanceScreen> {
  Map<String, dynamic>? _data;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await ApiService.fetchFinance();
      if (mounted) setState(() => _data = res);
    } catch (_) {
      if (mounted) setState(() => _error = "Couldn't load your finances.");
    }
  }

  Future<void> _delete(int id) async {
    await ApiService.deleteFinanceItem(id);
    _load();
  }

  void _planWithHari() {
    Navigator.of(context).popUntil((r) => r.isFirst);
    AssistantEngine.instance.askAssistant(
        'Look at my finance section and give me a plan: which EMI to close '
        'first and how to use my surplus this month.');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Neon.bg,
      floatingActionButton: FloatingActionButton(
        backgroundColor: Neon.textHi,
        foregroundColor: Neon.onInk,
        onPressed: () async {
          final added = await showDialog<bool>(
            context: context,
            builder: (_) => const _AddItemDialog(),
          );
          if (added == true) _load();
        },
        child: const Icon(Icons.add_rounded),
      ),
      body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 16, 0),
                child: Row(
                  children: [
                    IconButton(
                      icon: Icon(Icons.arrow_back_rounded,
                          color: Neon.textHi),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                    Text(
                      'Finance',
                      style: TextStyle(
                        color: Neon.textHi,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: _planWithHari,
                      icon: Icon(Icons.auto_awesome_rounded,
                          size: 16, color: Neon.textHi),
                      label: Text('Plan with ${AssistantIdentity.name}',
                          style: TextStyle(
                              color: Neon.textHi,
                              fontSize: 13,
                              fontWeight: FontWeight.w600)),
                    ),
                  ],
                ),
              ),
              Expanded(child: _body()),
            ],
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

    final items = (_data!['items'] as List? ?? const []).cast<Map>();
    final s = (_data!['summary'] as Map?) ?? const {};
    final incomes = items.where((i) => i['kind'] == 'income').toList();
    final emis = items.where((i) => i['kind'] == 'emi').toList();
    final expenses = items.where((i) => i['kind'] == 'expense').toList();

    if (items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'Nothing here yet.\n\nAdd your EMIs, incomes and expenses with '
            'the + button — or just tell ${AssistantIdentity.name}:\n"I have '
            'a bike EMI of ₹3,500 at 11 percent".',
            textAlign: TextAlign.center,
            style: TextStyle(color: Neon.textLo, fontSize: 14, height: 1.5),
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 90),
      children: [
        _summaryCard(s),
        const SizedBox(height: 14),
        if (emis.isNotEmpty) ...[
          const SectionHeader('EMIs — highest interest first'),
          ...emis.map(_itemCard),
          const SizedBox(height: 10),
        ],
        if (incomes.isNotEmpty) ...[
          const SectionHeader('Incoming'),
          ...incomes.map(_itemCard),
          const SizedBox(height: 10),
        ],
        if (expenses.isNotEmpty) ...[
          const SectionHeader('Recurring expenses'),
          ...expenses.map(_itemCard),
        ],
      ],
    );
  }

  Widget _summaryCard(Map s) {
    final surplus = (s['surplus'] as num?)?.toDouble() ?? 0;
    final good = surplus >= 0;
    Widget cell(String label, String value, {Color? color}) => Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style:
                      TextStyle(color: Neon.textDim, fontSize: 11)),
              const SizedBox(height: 3),
              Text(value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: color ?? Neon.textHi,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700)),
            ],
          ),
        );
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              cell('In / month', '₹${_fmt(s['monthly_income'])}'),
              cell('Out / month',
                  '₹${_fmt((s['monthly_emi'] as num? ?? 0) + (s['monthly_expense'] as num? ?? 0))}'),
              cell('Surplus', '₹${_fmt(surplus)}',
                  color: good ? Neon.success : Neon.error),
            ],
          ),
          if ((s['total_debt'] as num? ?? 0) > 0) ...[
            const SizedBox(height: 8),
            Text('Total debt outstanding: ₹${_fmt(s['total_debt'])}',
                style: TextStyle(color: Neon.textLo, fontSize: 12)),
          ],
        ],
      ),
    );
  }

  Widget _itemCard(Map e) {
    final kind = e['kind'] as String? ?? '';
    final isEmi = kind == 'emi';
    final isIncome = kind == 'income';
    final color = isIncome
        ? Neon.success
        : isEmi
            ? Neon.error
            : Neon.textLo;
    final chips = <String>[
      if (isEmi && (e['interest_rate'] as num? ?? 0) > 0)
        '${e['interest_rate']}% interest',
      if ((e['due_day'] as num? ?? 0) > 0) 'day ${e['due_day']}',
      if (isEmi && (e['outstanding'] as num? ?? 0) > 0)
        '₹${_fmt(e['outstanding'])} left',
    ];
    return Dismissible(
      key: ValueKey('fin-${e['id']}'),
      onDismissed: (_) => _delete((e['id'] as num).toInt()),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: GlassCard(
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(e['name'] ?? '',
                        style: TextStyle(
                            color: Neon.textHi,
                            fontSize: 15,
                            fontWeight: FontWeight.w600)),
                    if (chips.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(chips.join(' · '),
                          style: TextStyle(
                              color: Neon.textLo, fontSize: 12)),
                    ],
                  ],
                ),
              ),
              Text(
                '${isIncome ? '+' : '−'}₹${_fmt(e['amount'])}/mo',
                style: TextStyle(
                    color: color,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _fmt(dynamic n) {
    final v = (n as num?)?.toDouble() ?? 0;
    if (v == v.roundToDouble()) return v.toInt().toString();
    return v.toStringAsFixed(2);
  }
}

class _AddItemDialog extends StatefulWidget {
  const _AddItemDialog();

  @override
  State<_AddItemDialog> createState() => _AddItemDialogState();
}

class _AddItemDialogState extends State<_AddItemDialog> {
  String _kind = 'emi';
  final _name = TextEditingController();
  final _amount = TextEditingController();
  final _rate = TextEditingController();
  final _day = TextEditingController();
  final _outstanding = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [_name, _amount, _rate, _day, _outstanding]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final amount = double.tryParse(_amount.text.trim());
    if (_name.text.trim().isEmpty || amount == null || amount <= 0) return;
    setState(() => _saving = true);
    final ok = await ApiService.addFinanceItem({
      'kind': _kind,
      'name': _name.text.trim(),
      'amount': amount,
      if (_rate.text.trim().isNotEmpty)
        'interest_rate': double.tryParse(_rate.text.trim()),
      if (_day.text.trim().isNotEmpty)
        'due_day': int.tryParse(_day.text.trim()),
      if (_outstanding.text.trim().isNotEmpty)
        'outstanding': double.tryParse(_outstanding.text.trim()),
    });
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't save — check the values.")),
      );
    }
  }

  Widget _field(TextEditingController c, String label,
      {TextInputType type = TextInputType.number}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: c,
        keyboardType: type,
        style: TextStyle(color: Neon.textHi, fontSize: 14),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: TextStyle(color: Neon.textDim, fontSize: 13),
          isDense: true,
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide:
                BorderSide(color: Neon.lineBright),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: Neon.textHi, width: 1.4),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isEmi = _kind == 'emi';
    return AlertDialog(
      backgroundColor: Neon.surface,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      title: Text('Add finance item',
          style: TextStyle(color: Neon.textHi, fontSize: 17)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              children: [
                for (final k in const [
                  ['emi', 'EMI'],
                  ['income', 'Income'],
                  ['expense', 'Expense'],
                ])
                  ChoiceChip(
                    label: Text(k[1]),
                    selected: _kind == k[0],
                    selectedColor: Neon.textHi.withValues(alpha: 0.10),
                    labelStyle: TextStyle(
                        color: _kind == k[0] ? Neon.textHi : Neon.textLo,
                        fontSize: 12.5,
                        fontWeight: _kind == k[0]
                            ? FontWeight.w700
                            : FontWeight.w500),
                    onSelected: (_) => setState(() => _kind = k[0]),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            _field(_name, 'Name (Bike EMI, Salary…)',
                type: TextInputType.text),
            _field(_amount, 'Monthly amount (₹)'),
            if (isEmi) _field(_rate, 'Interest rate (% per year)'),
            _field(_day, 'Day of month it hits (1-31)'),
            if (isEmi) _field(_outstanding, 'Outstanding principal (₹)'),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text('Cancel',
              style: TextStyle(color: Neon.textDim)),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
              backgroundColor: Neon.textHi, foregroundColor: Neon.onInk),
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Saving…' : 'Save'),
        ),
      ],
    );
  }
}
