import 'package:flutter/material.dart';

import '../design/apple_kit.dart';
import '../design/neon_tokens.dart';
import '../design/neon_widgets.dart';
import '../features/assistant/state/assistant_engine.dart';
import '../core/log.dart';
import '../services/api_service.dart';
import '../services/app_feedback.dart';
import '../services/assistant_identity.dart';
import '../design/motion.dart';

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
      if (mounted) setState(() => _error = "Couldn't load your finances");
    }
  }

  Future<void> _delete(int id) async {
    var ok = false;
    try {
      ok = await ApiService.deleteFinanceItem(id);
    } catch (e) {
      AppLog.add('finance', 'delete $id -> $e');
    }
    if (!ok && mounted) {
      AppFeedback.show("Couldn't delete that.",
          context: context, tone: FeedbackTone.error);
    }
    _load();
  }

  void _planWithHari() {
    Navigator.of(context).popUntil((r) => r.isFirst);
    AssistantEngine.instance.askAssistant(
        'Look at my finance section and give me a plan: which EMI to close '
        'first and how to use my surplus this month.');
  }

  Future<void> _addItem() async {
    final added = await showAppDialog<bool>(
      context: context,
      builder: (_) => const _AddItemDialog(),
    );
    if (added == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    return NeonScaffold(
      appBar: appleAppBar(context, 'Finance', actions: [
        // Large text or a long assistant name used to push this past the
        // app bar's edge: capped in width, the label shortens instead, and
        // at very large text only the icon (with its tooltip) remains.
        if (MediaQuery.textScalerOf(context).scale(10) > 13)
          IconButton(
            tooltip: 'Plan with ${AssistantIdentity.name}',
            onPressed: _planWithHari,
            icon: Icon(Icons.auto_awesome_rounded,
                size: 20, color: AppleColors.blue),
          )
        else
          ConstrainedBox(
            constraints: BoxConstraints(
                maxWidth: MediaQuery.sizeOf(context).width * 0.42),
            child: TextButton.icon(
              onPressed: _planWithHari,
              icon: Icon(Icons.auto_awesome_rounded,
                  size: 16, color: AppleColors.blue),
              label: Text('Plan with ${AssistantIdentity.name}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: AppleColors.blue,
                      fontSize: 13,
                      fontWeight: FontWeight.w600)),
            ),
          ),
      ]),
      // The theme's lit FAB (2026-09-30): the page's primary action glows;
      // it was a flat white disc.
      // One "Add" on an empty screen: the empty state's (2026-09-30).
      floatingActionButton:
          ((_data?['items'] as List?)?.isEmpty ?? true)
              ? null
              : FloatingActionButton(
                  tooltip: 'Add finance item',
                  onPressed: _addItem,
                  child: const Icon(Icons.add_rounded),
                ),
      body: SafeArea(child: StateSwitch.of(_body())),
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
    if (_data == null) {
      return const NeonLoader.page(semanticLabel: 'Loading your finances');
    }

    final items = (_data!['items'] as List? ?? const []).cast<Map>();
    final s = (_data!['summary'] as Map?) ?? const {};
    final incomes = items.where((i) => i['kind'] == 'income').toList();
    final emis = items.where((i) => i['kind'] == 'emi').toList();
    final expenses = items.where((i) => i['kind'] == 'expense').toList();

    if (items.isEmpty) {
      return NeonEmptyState(
        icon: Icons.account_balance_wallet_rounded,
        title: 'Nothing here yet',
        body: 'Add your EMIs, incomes and expenses with the + button — or '
            'just tell ${AssistantIdentity.name}: "I have a bike EMI of '
            '₹3,500 at 11 percent".',
        actionLabel: 'Add an item',
        actionIcon: Icons.add_rounded,
        onAction: _addItem,
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 90),
      children: [
        _summaryCard(s),
        const SizedBox(height: 24),
        if (emis.isNotEmpty) ...[
          const GroupLabel('EMIs — highest interest first'),
          GroupedCard(children: emis.map(_itemRow).toList()),
          const SizedBox(height: 24),
        ],
        if (incomes.isNotEmpty) ...[
          const GroupLabel('Incoming'),
          GroupedCard(children: incomes.map(_itemRow).toList()),
          const SizedBox(height: 24),
        ],
        if (expenses.isNotEmpty) ...[
          const GroupLabel('Recurring expenses'),
          GroupedCard(children: expenses.map(_itemRow).toList()),
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
                  style: TextStyle(
                      color: Neon.textLo, fontSize: NeonType.caption)),
              const SizedBox(height: 3),
              Text(value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: color ?? Neon.textHi,
                      fontSize: 15,
                      fontWeight: FontWeight.w700)),
            ],
          ),
        );
    // The page's one lit card (2026-09-30): the month's totals, in the
    // blue of information.
    return GlowCard(
      tone: NeonTone.info,
      halo: 0.6,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              cell('In / month', '₹${_fmt(s['monthly_income'])}'),
              cell('Out / month',
                  '₹${_fmt((s['monthly_emi'] as num? ?? 0) + (s['monthly_expense'] as num? ?? 0))}'),
              cell('Surplus', '₹${_fmt(surplus)}',
                  color: good ? Neon.successInk : Neon.errorInk),
            ],
          ),
          if ((s['total_debt'] as num? ?? 0) > 0) ...[
            const SizedBox(height: 8),
            Text('Total debt outstanding: ₹${_fmt(s['total_debt'])}',
                style:
                    TextStyle(color: Neon.textLo, fontSize: NeonType.caption)),
          ],
        ],
      ),
    );
  }

  Widget _itemRow(Map e) {
    final kind = e['kind'] as String? ?? '';
    final isEmi = kind == 'emi';
    final isIncome = kind == 'income';
    final color = isIncome
        ? Neon.successInk
        : isEmi
            ? Neon.errorInk
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
      child: AppleRow(
        title: e['name'] ?? '',
        subtitle: chips.isNotEmpty ? chips.join(' · ') : null,
        trailing: Text(
          '${isIncome ? '+' : '−'}₹${_fmt(e['amount'])}/mo',
          style: TextStyle(
              color: color, fontSize: 15, fontWeight: FontWeight.w700),
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

  /// Said inside the dialog: a toast would land behind it, unseen.
  String? _problem;

  @override
  void dispose() {
    for (final c in [_name, _amount, _rate, _day, _outstanding]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final amount = double.tryParse(_amount.text.trim());
    if (_name.text.trim().isEmpty || amount == null || amount <= 0) {
      setState(() => _problem = 'Add a name and an amount above zero.');
      return;
    }
    setState(() {
      _saving = true;
      _problem = null;
    });
    var ok = false;
    try {
      ok = await ApiService.addFinanceItem({
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
    } catch (e) {
      AppLog.add('finance', 'add -> $e');
    }
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _saving = false;
        _problem = "Couldn't save — check the values and your connection.";
      });
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
          labelStyle:
              TextStyle(color: Neon.textLo, fontSize: NeonType.footnote),
          isDense: true,
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: Neon.lineBright),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: Neon.violet, width: 1.4),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isEmi = _kind == 'emi';
    // The theme's dialog, chips and buttons (2026-09-30): the local
    // colours matched them and kept the lit rim and Save's glow off.
    return AlertDialog(
      title: const Text('Add finance item'),
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
                    labelStyle: TextStyle(
                        color: _kind == k[0] ? Neon.textHi : Neon.textLo,
                        fontWeight:
                            _kind == k[0] ? FontWeight.w700 : FontWeight.w500),
                    onSelected: (_) => setState(() => _kind = k[0]),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            _field(_name, 'Name (Bike EMI, Salary…)', type: TextInputType.text),
            _field(_amount, 'Monthly amount (₹)'),
            if (isEmi) _field(_rate, 'Interest rate (% per year)'),
            _field(_day, 'Day of month it hits (1-31)'),
            if (isEmi) _field(_outstanding, 'Outstanding principal (₹)'),
            if (_problem != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(_problem!,
                    style: TextStyle(color: Neon.errorInk, fontSize: 13)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Saving…' : 'Save'),
        ),
      ],
    );
  }
}
