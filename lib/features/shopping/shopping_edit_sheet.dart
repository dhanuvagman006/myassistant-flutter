import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/log.dart';
import '../../design/motion.dart';
import '../../design/neon_tokens.dart';
import 'shopping_models.dart';
import 'shopping_parse.dart';

/// What the edit sheet decided: the fields that changed, or "remove it".
class ShoppingEditResult {
  const ShoppingEditResult.save(this.patch) : remove = false;
  const ShoppingEditResult.remove()
      : patch = const {},
        remove = true;

  /// Only what changed, as PATCH /shopping/items/:id takes it.
  final Map<String, dynamic> patch;
  final bool remove;
}

/// One line, edited: name, amount, details, where from, link, kind.
Future<ShoppingEditResult?> showShoppingEditSheet(
  BuildContext context, {
  required ShoppingItem item,
  required List<ShoppingCategory> categories,
}) =>
    showAppSheet<ShoppingEditResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Neon.surface,
      showDragHandle: true,
      builder: (_) => ShoppingEditSheet(item: item, categories: categories),
    );

/// An https address the list keeps (the server's rule), or null.
String? cleanShoppingLink(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return '';
  if (!s.contains('://')) s = 'https://$s';
  final u = Uri.tryParse(s);
  if (u == null || u.scheme != 'https' || u.host.isEmpty || s.length > 500) return null;
  return s;
}

class ShoppingEditSheet extends StatefulWidget {
  const ShoppingEditSheet({super.key, required this.item, required this.categories});

  final ShoppingItem item;
  final List<ShoppingCategory> categories;

  @override
  State<ShoppingEditSheet> createState() => _ShoppingEditSheetState();
}

class _ShoppingEditSheetState extends State<ShoppingEditSheet> {
  late final ShoppingItem _item = widget.item;
  late final _name = TextEditingController(text: _item.name);
  late final _amount = TextEditingController(text: _item.amountText);
  late final _details = TextEditingController(text: _item.details);
  late final _store = TextEditingController(text: _item.store ?? '');
  late final _link = TextEditingController(text: _item.link ?? '');
  late String _category = _item.category;
  String? _nameError;
  String? _amountError;
  String? _linkError;

  @override
  void dispose() {
    _name.dispose();
    _amount.dispose();
    _details.dispose();
    _store.dispose();
    _link.dispose();
    super.dispose();
  }

  static String _spaces(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

  void _save() {
    final patch = <String, dynamic>{};
    final name = cleanItemName(_name.text);
    String? nameError;
    String? amountError;
    String? linkError;
    if (name.isEmpty) {
      nameError = 'Type what to buy.';
    } else if (name.length > shoppingNameMax) {
      nameError = '80 letters at most — put the rest in the details.';
    } else if (name != _item.name) {
      patch['name'] = name;
    }
    final amount = _spaces(_amount.text);
    if (amount != _spaces(_item.amountText)) {
      final a = parseAmount(amount);
      if (a == null) {
        amountError = 'Try an amount like “2 kg”, “1 packet” or “3”.';
      } else {
        patch['quantity'] = a.quantity;
        patch['unit'] = a.unit;
      }
    }
    final details = _spaces(_details.text);
    if (details != _item.details) patch['details'] = details;
    final store = _spaces(_store.text);
    if (store != (_item.store ?? '')) patch['store'] = store.isEmpty ? null : store;
    final link = cleanShoppingLink(_link.text);
    if (link == null) {
      linkError = 'Use a web address starting with https://';
    } else if (link != (_item.link ?? '')) {
      patch['link'] = link.isEmpty ? null : link;
    }
    if (_category != _item.category) patch['category'] = _category;
    if (nameError != null || amountError != null || linkError != null) {
      setState(() {
        _nameError = nameError;
        _amountError = amountError;
        _linkError = linkError;
      });
      return;
    }
    Navigator.of(context).pop(ShoppingEditResult.save(patch));
  }

  Future<void> _openLink() async {
    final link = cleanShoppingLink(_link.text);
    if (link == null || link.isEmpty) return;
    try {
      await launchUrl(Uri.parse(link), mode: LaunchMode.externalApplication);
    } catch (e) {
      AppLog.add('shop', 'link would not open: $e');
    }
  }

  InputDecoration _box(String label, {String? hint, String? error, Widget? suffix}) =>
      InputDecoration(
        labelText: label,
        hintText: hint,
        errorText: error,
        suffixIcon: suffix,
        counterText: '',
        // The rest is the theme's field (2026-09-30): the same fill, lit
        // hairline and focus as every other field in the app.
        errorStyle: TextStyle(color: Neon.errorInk, fontSize: NeonType.footnote),
      );

  @override
  Widget build(BuildContext context) {
    final text = TextStyle(color: Neon.textHi, fontSize: NeonType.body);
    final hasLink = (cleanShoppingLink(_link.text) ?? '').isNotEmpty;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Edit', style: NeonType.cardTitle.copyWith(color: Neon.textHi)),
            const SizedBox(height: 14),
            TextField(
              key: const Key('edit_name'),
              controller: _name,
              maxLength: shoppingNameMax,
              textCapitalization: TextCapitalization.sentences,
              style: text,
              decoration: _box('What', hint: 'e.g. Kurti', error: _nameError),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('edit_amount'),
              controller: _amount,
              style: text,
              decoration: _box('How much', hint: '2 kg, 1 packet, 3', error: _amountError),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('edit_details'),
              controller: _details,
              maxLength: 200,
              textCapitalization: TextCapitalization.sentences,
              style: text,
              decoration: _box('Details', hint: 'Size, colour, brand — M, blue floral'),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('edit_store'),
              controller: _store,
              maxLength: 40,
              textCapitalization: TextCapitalization.words,
              style: text,
              decoration: _box('From', hint: 'A shop or app — Myntra, the kirana'),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('edit_link'),
              controller: _link,
              keyboardType: TextInputType.url,
              style: text,
              onChanged: (_) => setState(() {}),
              decoration: _box(
                'Link',
                hint: 'https://…',
                error: _linkError,
                suffix: hasLink
                    ? IconButton(
                        tooltip: 'Open the link',
                        onPressed: _openLink,
                        icon: Icon(Icons.open_in_new_rounded, color: Neon.textLo),
                      )
                    : null,
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: const Key('edit_category'),
              initialValue: widget.categories.any((c) => c.id == _category) ? _category : null,
              isExpanded: true,
              style: text,
              decoration: _box('Kind'),
              items: [
                for (final c in widget.categories)
                  DropdownMenuItem(value: c.id, child: Text(c.label, overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (v) {
                if (v != null) setState(() => _category = v);
              },
            ),
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              runSpacing: 8,
              children: [
                TextButton.icon(
                  key: const Key('edit_remove'),
                  onPressed: () => Navigator.of(context).pop(const ShoppingEditResult.remove()),
                  icon: Icon(Icons.delete_outline_rounded, color: Neon.errorInk),
                  label: Text('Remove', style: TextStyle(color: Neon.errorInk)),
                  style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
                      child: Text('Cancel', style: TextStyle(color: Neon.textLo)),
                    ),
                    const SizedBox(width: 6),
                    FilledButton(
                      key: const Key('edit_save'),
                      onPressed: _save,
                      // The theme's lit fill; only the pill shape is this sheet's.
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(88, 48),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Neon.rPill)),
                      ),
                      child: const Text('Save'),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
