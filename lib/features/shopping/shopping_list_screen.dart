import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/log.dart';
import '../../design/apple_kit.dart';
import '../../design/motion.dart';
import '../../design/neon_tokens.dart';
import '../../design/neon_widgets.dart';
import '../../services/app_feedback.dart';
import '../../services/auth_service.dart';
import '../../services/avatar_message_service.dart';
import 'shop_handoff.dart';
import 'shopping_edit_sheet.dart';
import 'shopping_models.dart';
import 'shopping_parse.dart';
import 'shopping_service.dart';

/// Opens the list from anywhere (a notification, the assistant) without
/// stacking a second one.
abstract final class ShoppingNav {
  static Future<void> open({String? category}) async {
    for (var i = 0; i < 24; i++) {
      final nav = AvatarMessageService.navigatorKey.currentState;
      if (nav != null && AuthService.instance.user != null) {
        if (ShoppingListScreen.showing == 0) {
          unawaited(nav.push(MaterialPageRoute(builder: (_) => ShoppingListScreen(category: category))));
        } else {
          unawaited(ShoppingService.instance.refresh());
        }
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  /// A tap on the shopping trip's notification: 'shopping' (the list),
  /// 'shopping:next' (the following thing), 'shopping:done' (the end).
  static Future<void> fromNotification(String what) async {
    switch (what) {
      case 'shopping:next':
        final r = await ShopHandoffRunner.instance.next();
        if (r.opened) return;
        if (r.step != null) {
          AppFeedback.toast("Couldn't open ${r.step!.item.name} — tap Next for the one after it.",
              tone: FeedbackTone.error);
          return;
        }
        await open();
        AppFeedback.toast(r.finished
            ? 'That was the last one — tick what you bought.'
            : 'That shopping trip has ended — here is your list.');
      case 'shopping:done':
        await ShopHandoffRunner.instance.end();
        await open();
        AppFeedback.toast('Tick off what you bought.');
      default:
        await open();
    }
  }
}

/// ─────────────────────────────────────────────────────────────────────────
///  THE SHOPPING LIST (Hub → Your day → Shopping list, or "show my shopping
///  list") — one list for anything to buy: groceries, a dress, a charger.
///
///  Owner, 2026-09-29: "the shopping list should not be specific to
///  cooking — a dress or anything: if I just say 'add this to my shopping
///  list', even during a normal conversation, my assistant should do it."
///
///  Grouped by kind (the server's labels); tap a line to tick it, hold to
///  edit, swipe to remove (with Undo). Typing at the top adds a line
///  ("2 kg onions", "blue kurti size M"). "Shop these" opens each thing in
///  the app that sells it — the owner chooses and pays there; nothing is
///  ordered from here.
/// ─────────────────────────────────────────────────────────────────────────
class ShoppingListScreen extends StatefulWidget {
  const ShoppingListScreen({super.key, this.category});

  /// Only this kind ("show my grocery list" → one category), with a way
  /// back to everything.
  final String? category;

  /// How many are open (ShoppingNav does not stack a second).
  static int showing = 0;

  /// Hands the list's text to the phone's share sheet, where WhatsApp is
  /// (tests record instead).
  static Future<void> Function(String text) share =
      (text) => Share.share(text, subject: 'Shopping list');

  @override
  State<ShoppingListScreen> createState() => _ShoppingListScreenState();
}

class _ShoppingListScreenState extends State<ShoppingListScreen> with WidgetsBindingObserver {
  final _svc = ShoppingService.instance;
  final _add = TextEditingController();
  final _addFocus = FocusNode();
  String? _addError;
  String? _filter;
  bool _showBought = false;
  bool _shopping = false;

  /// Lines just ticked stay where they were for a moment (the owner sees
  /// what they ticked; the next line does not slide under their finger).
  final Map<int, Timer> _settling = {};

  static const _settle = Duration(milliseconds: 1500);

  @override
  void initState() {
    super.initState();
    ShoppingListScreen.showing++;
    final c = widget.category;
    _filter = c != null && shoppingCategories.any((x) => x.id == c) ? c : null;
    WidgetsBinding.instance.addObserver(this);
    unawaited(_svc.load());
  }

  @override
  void dispose() {
    ShoppingListScreen.showing--;
    WidgetsBinding.instance.removeObserver(this);
    for (final t in _settling.values) {
      t.cancel();
    }
    _add.dispose();
    _addFocus.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from the shopping app: the assistant may have ticked things.
    if (state == AppLifecycleState.resumed) unawaited(_svc.refresh());
  }

  // ------------------------------------------------------------- feedback

  /// A change that did not go through: said, with Try again when trying
  /// again can help.
  void _report(ShoppingResult r, VoidCallback retry) {
    if (r.ok) return;
    final ctx = mounted ? context : null;
    if (r.canRetry) {
      AppFeedback.showRetry(r.error!, context: ctx, onRetry: retry);
    } else {
      AppFeedback.show(r.error!, context: ctx, tone: FeedbackTone.error);
    }
  }

  // -------------------------------------------------------------- actions

  Future<void> _submitAdd() async {
    final text = _add.text;
    if (text.trim().isEmpty) return;
    final parsed = parseQuickAdd(text);
    final draft = parsed.draft;
    if (draft == null) {
      setState(() => _addError = parsed.error);
      return;
    }
    setState(() => _addError = null);
    _add.clear();
    _addFocus.requestFocus();
    final r = await _svc.add(draft);
    if (!mounted) return;
    if (!r.ok) {
      // Nothing typed is lost: the words go back in the box.
      if (_add.text.isEmpty) {
        _add.value = TextEditingValue(
            text: text, selection: TextSelection.collapsed(offset: text.length));
      }
      _report(r, () => unawaited(_submitAdd()));
      return;
    }
    final merged = r.merged;
    final added = r.added;
    final filter = _filter;
    if (merged != null) {
      AppFeedback.show(
          '${merged.name} was already on your list'
          '${merged.amountText.isEmpty ? '' : ' — now ${merged.amountText}'}.',
          context: context,
          tone: FeedbackTone.success);
    } else if (added != null && filter != null && added.category != filter) {
      // Showing one kind, and it went under another: say where it is
      // rather than let it seem to vanish.
      AppFeedback.show('Added ${added.name} — it is under ${_svc.labelOf(added.category)}.',
          context: context, tone: FeedbackTone.success);
    }
  }

  void _toggle(ShoppingItem item) {
    if (item.pending) return;
    HapticFeedback.selectionClick();
    final want = !item.checked;
    _settling.remove(item.id)?.cancel();
    if (want) {
      _settling[item.id] = Timer(_settle, () {
        if (mounted) setState(() => _settling.remove(item.id));
      });
    }
    unawaited(_svc.setChecked(item, want).then((r) {
      if (r.ok) return;
      _settling.remove(item.id)?.cancel();
      if (mounted) setState(() {});
      _report(r, () {
        final now = _svc.byId(item.id);
        if (now != null && now.checked != want) _toggle(now);
      });
    }));
  }

  void _remove(ShoppingItem item) {
    if (item.pending) return;
    HapticFeedback.mediumImpact();
    _settling.remove(item.id)?.cancel();
    final pending = _svc.removeLater(item);
    AppFeedback.showUndo(context, 'Removed ${item.name}', onUndo: pending.cancel).then((why) async {
      if (why == SnackBarClosedReason.action) return;
      final r = await pending.commit();
      _report(r, () => unawaited(_svc.retryRemove(item).then((r2) => _report(r2, () {}))));
    });
  }

  void _clearBought(int n) {
    HapticFeedback.mediumImpact();
    final pending = _svc.clearBoughtLater();
    AppFeedback.showUndo(context, 'Cleared $n bought ${n == 1 ? 'thing' : 'things'}',
            onUndo: pending.cancel)
        .then((why) async {
      if (why == SnackBarClosedReason.action) return;
      final r = await pending.commit();
      _report(r, () => unawaited(_svc.clearBoughtLater().commit().then((r2) => _report(r2, () {}))));
    });
  }

  Future<void> _edit(ShoppingItem item) async {
    if (item.pending) return;
    final res = await showShoppingEditSheet(context, item: item, categories: _svc.categories);
    if (res == null || !mounted) return;
    final now = _svc.byId(item.id) ?? item;
    if (res.remove) {
      _remove(now);
      return;
    }
    if (res.patch.isEmpty) return;
    Future<void> send() async {
      final r = await _svc.update(_svc.byId(item.id) ?? now, res.patch);
      _report(r, () => unawaited(send()));
    }

    await send();
  }

  Future<void> _share() async {
    final r = await _svc.shareText(category: _filter);
    if (!mounted) return;
    if (r.error != null) {
      _report(ShoppingResult.failed(r.error!, canRetry: r.canRetry), () => unawaited(_share()));
      return;
    }
    final text = r.text ?? '';
    if (text.isEmpty) {
      AppFeedback.show('Nothing left to buy — there is nothing to share.', context: context);
      return;
    }
    try {
      await ShoppingListScreen.share(text);
    } catch (e) {
      AppLog.add('shop', 'share sheet failed: $e');
      if (mounted) {
        AppFeedback.show("Couldn't open sharing on this phone.",
            context: context, tone: FeedbackTone.error);
      }
    }
  }

  Future<void> _clearAll() async {
    final n = _svc.items.where((i) => !i.pending).length;
    if (n == 0) return;
    final yes = await showAppDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Clear the whole list?'),
        content: Text('All $n ${n == 1 ? 'thing' : 'things'}, bought or not, will be removed. '
            'This can’t be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep')),
          FilledButton(
            key: const Key('confirm_clear_all'),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Clear all'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    Future<void> send() async {
      final r = await _svc.clearAll();
      if (r.ok) {
        if (mounted) {
          AppFeedback.show('Your list is empty.', context: context, tone: FeedbackTone.success);
        }
        return;
      }
      _report(r, () => unawaited(send()));
    }

    await send();
  }

  /// "Shop these": each thing opens in the app that sells it.
  Future<void> _shop() async {
    if (_shopping) return;
    final filter = _filter;
    final ids = filter == null
        ? null
        : [
            for (final i in _svc.items)
              if (i.category == filter && !i.checked && !i.pending) i.id
          ];
    if (ids != null && ids.isEmpty) return;
    setState(() => _shopping = true);
    try {
      var reply = await _svc.handoff(ids: ids);
      if (!mounted) return;
      if (reply.error == null && reply.needsGroceryApp.isNotEmpty) {
        // Waiting on the owner, not the network: no spinner behind the sheet.
        setState(() => _shopping = false);
        final app = await _askGroceryApp(reply.needsGroceryApp, reply.groceryApps);
        if (app == null || !mounted) return;
        setState(() => _shopping = true);
        reply = await _svc.handoff(ids: ids, groceryApp: app);
        if (!mounted) return;
      }
      if (reply.error != null) {
        _report(ShoppingResult.failed(reply.error!, canRetry: reply.canRetry), () => unawaited(_shop()));
        return;
      }
      final h = reply.handoff;
      if (h == null) {
        AppFeedback.show(
            reply.needsGroceryApp.isNotEmpty
                ? "I still don't know which app to use for groceries — nothing was opened."
                : 'Nothing left to buy — nothing was opened.',
            context: context);
        return;
      }
      final r = await ShopHandoffRunner.instance.start(h);
      if (!mounted || r.opened) return;
      _report(
          ShoppingResult.failed(
              r.step == null
                  ? "Those links can't be opened safely — nothing was opened."
                  : "Couldn't open the shopping app — nothing was opened.",
              canRetry: r.step != null),
          () => unawaited(_shop()));
    } finally {
      if (mounted) setState(() => _shopping = false);
    }
  }

  Future<String?> _askGroceryApp(List<String> names, List<String> apps) {
    final what = names.length <= 2
        ? names.join(' and ')
        : '${names.take(2).join(', ')} and ${names.length - 2} more';
    return showAppSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => GroceryAppSheet(what: what, apps: apps),
    );
  }

  // ---------------------------------------------------------------- views

  List<ShoppingItem> get _visible {
    final f = _filter;
    final all = _svc.items;
    return f == null ? all : [for (final i in all) if (i.category == f || i.pending) i];
  }

  bool _toBuy(ShoppingItem i) => !i.checked || _settling.containsKey(i.id);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _svc,
      builder: (context, _) {
        final visible = _visible;
        final canShop = _svc.loaded &&
            visible.any((i) => !i.checked && !i.pending) &&
            MediaQuery.viewInsetsOf(context).bottom == 0;
        // Under Home's sky (2026-09-30).
        return NeonScaffold(
          appBar: appleAppBar(context, 'Shopping list', actions: [_menu(visible)]),
          floatingActionButton: canShop
              ? FloatingActionButton.extended(
                  key: const Key('shop_these'),
                  heroTag: 'shop_these',
                  tooltip: 'Open each thing in its shopping app — you choose and pay there',
                  onPressed: _shopping ? null : _shop,
                  // The theme's lit FAB: the page's one primary action.
                  icon: _shopping
                      ? const NeonLoader.inline(
                          size: 20, semanticLabel: 'Opening the shops')
                      : const Icon(Icons.shopping_bag_rounded),
                  label: const Text('Shop these'),
                )
              : null,
          // Only the add box stays put; the notes scroll with the list, so
          // at large text sizes they never squeeze it off the screen.
          body: SafeArea(
            child: Column(
              children: [
                _quickAdd(),
                Expanded(
                  child: LoadSwitch(
                    loading: !_svc.loaded && !_svc.failed,
                    spinner: const _ListSkeleton(),
                    child: _content(visible, notes: [
                      if (_svc.failed && _svc.loaded) _offlineNote(),
                      if (_filter != null && _svc.loaded) _filterNote(),
                    ]),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _menu(List<ShoppingItem> visible) {
    final anyToBuy = visible.any((i) => !i.checked && !i.pending);
    final any = _svc.items.any((i) => !i.pending);
    return PopupMenuButton<String>(
      popUpAnimationStyle: appMenuAnimation(context),
      key: const Key('shopping_menu'),
      tooltip: 'More',
      icon: Icon(Icons.more_vert_rounded, color: Neon.textHi),
      onSelected: (v) {
        if (v == 'share') {
          unawaited(_share());
        } else {
          unawaited(_clearAll());
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(value: 'share', enabled: anyToBuy, child: const Text('Share list')),
        PopupMenuItem(value: 'clear', enabled: any, child: const Text('Clear all…')),
      ],
    );
  }

  // THE ADD BOX IS THE PAGE'S LIT CARD (2026-09-30): adding is what
  // this page is for, so its box wears the brand's rim and a soft glow;
  // the field itself is borderless inside it.
  Widget _quickAdd() {
    const border = OutlineInputBorder(
      borderRadius: BorderRadius.all(Radius.circular(Neon.rMd - 1.4)),
      borderSide: BorderSide.none,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: GlowCard(
        radius: Neon.rMd,
        rimWidth: 1.4,
        halo: 0.45,
        child: TextField(
        key: const Key('shopping_quick_add'),
        controller: _add,
        focusNode: _addFocus,
        textCapitalization: TextCapitalization.sentences,
        textInputAction: TextInputAction.done,
        maxLength: 160,
        style: TextStyle(color: Neon.textHi, fontSize: NeonType.body),
        onChanged: (_) {
          if (_addError != null) setState(() => _addError = null);
        },
        // Keeps the keyboard up: add one thing, then the next.
        onEditingComplete: () => unawaited(_submitAdd()),
        decoration: InputDecoration(
          hintText: 'Add — “2 kg onions”, “blue kurti size M”',
          hintStyle: TextStyle(color: Neon.textDim),
          hintMaxLines: 1,
          counterText: '',
          errorText: _addError,
          errorMaxLines: 2,
          errorStyle: TextStyle(color: Neon.errorInk, fontSize: NeonType.footnote),
          prefixIcon: Icon(Icons.add_rounded, color: Neon.violet),
          suffixIcon: ValueListenableBuilder<TextEditingValue>(
            valueListenable: _add,
            builder: (context, v, _) => v.text.trim().isEmpty
                ? const SizedBox.shrink()
                : IconButton(
                    key: const Key('shopping_add_button'),
                    tooltip: 'Add to the list',
                    onPressed: () => unawaited(_submitAdd()),
                    icon: Icon(Icons.arrow_upward_rounded, color: Neon.violet),
                  ),
          ),
          filled: false,
          border: border,
          enabledBorder: border,
          focusedBorder: border,
          errorBorder: border,
          focusedErrorBorder: border,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        ),
      ),
      ),
    );
  }

  // An amber rim, unlit: a state to notice, not the page's news.
  Widget _offlineNote() => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: GlowCard(
          tone: NeonTone.warning,
          halo: 0,
          rimWidth: 1.2,
          radius: Neon.rSm,
          padding: const EdgeInsets.fromLTRB(10.8, 2.8, 2.8, 2.8),
          child: Row(
            children: [
              Icon(Icons.cloud_off_rounded, size: 18, color: Neon.warningInk),
              const SizedBox(width: 10),
              Expanded(
                child: Text("Can't reach the server — this is your last saved list.",
                    style: TextStyle(color: Neon.textLo, fontSize: NeonType.footnote, height: 1.3)),
              ),
              TextButton(
                onPressed: () => unawaited(_svc.refresh()),
                child: const Text('Try again'),
              ),
            ],
          ),
        ),
      );

  // A Wrap: at large text sizes the button moves under the words instead
  // of pushing past the edge (layout sweep, huge text).
  Widget _filterNote() => Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 0, 4),
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          children: [
            Text.rich(
              TextSpan(children: [
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: Icon(Icons.filter_list_rounded, size: 18, color: Neon.textLo),
                ),
                TextSpan(text: '  Only ${_svc.labelOf(_filter!)}'),
              ]),
              style: TextStyle(color: Neon.textHi, fontSize: NeonType.body),
            ),
            TextButton(
              key: const Key('show_everything'),
              onPressed: () => setState(() => _filter = null),
              child: const Text('Show everything'),
            ),
          ],
        ),
      );

  Widget _content(List<ShoppingItem> visible, {List<Widget> notes = const []}) {
    if (!_svc.loaded) {
      return NeonErrorState(
        key: const Key('shopping_error'),
        message: "Couldn't load your list",
        onRetry: () => unawaited(_svc.load()),
      );
    }
    final toBuy = [for (final i in visible) if (_toBuy(i)) i];
    final bought = [for (final i in visible) if (!_toBuy(i)) i];
    if (toBuy.isEmpty && bought.isEmpty) {
      return RefreshIndicator(
        color: Neon.violet,
        onRefresh: _svc.refresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          children: [
            ...notes,
            const SizedBox(height: 40),
            NeonEmptyState(
              icon: Icons.shopping_basket_rounded,
              title: _filter == null
                  ? 'Nothing to buy yet'
                  : 'Nothing in ${_svc.labelOf(_filter!)}',
              body: 'Say “add milk to my shopping list”, or type it above — '
                  '“2 kg onions”, “blue kurti size M”.',
            ),
          ],
        ),
      );
    }
    final pending = [for (final i in toBuy) if (i.pending) i];
    final groups = <String, List<ShoppingItem>>{};
    for (final i in toBuy) {
      if (i.pending) continue;
      final known = _svc.categories.any((c) => c.id == i.category);
      groups.putIfAbsent(known ? i.category : 'other', () => []).add(i);
    }
    final order = [for (final c in _svc.categories) if (groups.containsKey(c.id)) c.id];
    if (groups.containsKey('other') && !order.contains('other')) order.add('other');
    return RefreshIndicator(
      color: Neon.violet,
      onRefresh: _svc.refresh,
      child: ListView(
        key: const Key('shopping_list'),
        padding: EdgeInsets.fromLTRB(16, 4, 16, 120 + MediaQuery.paddingOf(context).bottom),
        children: [
          ...notes,
          if (toBuy.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 12),
              child: Text('Tap to tick · hold to edit · swipe to remove',
                  style: TextStyle(color: Neon.textLo, fontSize: NeonType.footnote)),
            ),
          if (pending.isNotEmpty) ...[
            GroupedCard(dividerInset: 60, children: [for (final i in pending) _row(i)]),
            const SizedBox(height: 18),
          ],
          for (final id in order) ...[
            GroupLabel(_svc.labelOf(id)),
            GroupedCard(dividerInset: 60, children: [for (final i in groups[id]!) _row(i)]),
            const SizedBox(height: 18),
          ],
          if (toBuy.isEmpty) _allBought(),
          if (bought.isNotEmpty) ...[
            Row(
              children: [
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const Key('bought_toggle'),
                      onPressed: () => setState(() => _showBought = !_showBought),
                      icon: ExpandChevron(open: _showBought, color: Neon.textLo),
                      label: Text('Bought (${bought.length})',
                          style: TextStyle(color: Neon.textLo, fontSize: NeonType.body)),
                    ),
                  ),
                ),
                TextButton(
                  key: const Key('clear_bought'),
                  onPressed: () => _clearBought(bought.length),
                  child: const Text('Clear bought'),
                ),
              ],
            ),
            Collapse(
              open: _showBought,
              child: GroupedCard(dividerInset: 60, children: [for (final i in bought) _row(i)]),
            ),
          ],
        ],
      ),
    );
  }

  // Done, drawn as done (2026-09-30): the app's tick in a card lit
  // the green of done-and-well.
  Widget _allBought() => Padding(
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 16),
        child: GlowCard(
          tone: NeonTone.success,
          halo: 0.5,
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Row(
            children: [
              const NeonSuccess(size: 28),
              const SizedBox(width: 12),
              Expanded(
                child: Text('Everything is bought.',
                    style: NeonType.manrope(NeonType.rowTitle, FontWeight.w600)
                        .copyWith(color: Neon.textHi)),
              ),
            ],
          ),
        ),
      );

  Widget _row(ShoppingItem item) {
    final checked = item.checked;
    final sub = [
      if (item.pending) 'Adding…',
      if (item.details.isNotEmpty) item.details,
      if ((item.store ?? '').isNotEmpty) 'From ${item.store}',
      if (item.linkHost != null) item.linkHost!,
    ].join(' · ');
    final spoken = [
      item.name,
      if (item.amountText.isNotEmpty) item.amountText,
      if (item.details.isNotEmpty) item.details,
      if ((item.store ?? '').isNotEmpty) 'from ${item.store}',
      if (item.pending) 'adding',
    ].join(', ');
    final row = Semantics(
      container: true,
      checked: item.pending ? null : checked,
      label: spoken,
      onTapHint: checked ? 'mark as not bought' : 'tick as bought',
      onLongPressHint: 'edit',
      customSemanticsActions: item.pending
          ? null
          : {
              const CustomSemanticsAction(label: 'Edit'): () => unawaited(_edit(item)),
              const CustomSemanticsAction(label: 'Remove'): () => _remove(item),
            },
      // The row dips under the finger like every AppleRow (2026-09-30).
      child: PressScale(
        scale: 0.985,
        child: InkWell(
        onTap: item.pending ? null : () => _toggle(item),
        onLongPress: item.pending ? null : () => unawaited(_edit(item)),
        child: ExcludeSemantics(
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 14, 6),
              child: Row(
                children: [
                  SizedBox(
                    width: 48,
                    height: 48,
                    child: Center(
                      child: item.pending
                          ? const NeonLoader.inline(semanticLabel: 'Adding')
                          : AnimatedSwitcher(switchInCurve: Motion.easeEnter, switchOutCurve: Motion.easeFadeOut, 
                              duration: Motion.reduced(context) ? Duration.zero : Motion.micro,
                              child: Icon(
                                checked
                                    ? Icons.check_circle_rounded
                                    : Icons.radio_button_unchecked_rounded,
                                key: ValueKey(checked),
                                color: checked ? Neon.success : Neon.violet,
                                size: 24,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          item.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: NeonType.row.copyWith(
                            color: checked ? Neon.textDim : Neon.textHi,
                            decoration: checked ? TextDecoration.lineThrough : null,
                          ),
                        ),
                        if (sub.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(sub,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: Neon.textLo, fontSize: NeonType.footnote, height: 1.3)),
                        ],
                      ],
                    ),
                  ),
                  if (item.amountText.isNotEmpty) ...[
                    const SizedBox(width: 10),
                    Text(
                      item.amountText,
                      style: NeonType.manrope(NeonType.body, FontWeight.w600)
                          .copyWith(color: checked ? Neon.textDim : Neon.textLo),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
      ),
    );
    if (item.pending) return row;
    return Dismissible(
      key: ValueKey('shop-${item.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        color: Neon.error.withValues(alpha: 0.18),
        child: Icon(Icons.delete_outline_rounded, color: Neon.errorInk),
      ),
      onDismissed: (_) => _remove(item),
      child: row,
    );
  }
}

/// "Which app do you use for groceries?" — asked once; the server
/// remembers the answer.
class GroceryAppSheet extends StatelessWidget {
  const GroceryAppSheet({super.key, required this.what, required this.apps});

  /// "onions, milk and 3 more"
  final String what;
  final List<String> apps;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Which app do you use for groceries?',
                style: NeonType.cardTitle.copyWith(color: Neon.textHi)),
            const SizedBox(height: 6),
            Text('For $what. I’ll remember it for next time.',
                style: TextStyle(color: Neon.textLo, fontSize: NeonType.body, height: 1.35)),
            const SizedBox(height: 14),
            for (final a in apps) ...[
              OutlinedButton(
                key: Key('grocery_app_$a'),
                onPressed: () => Navigator.of(context).pop(a),
                // The theme's rim (2026-09-30): each app a secondary choice.
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Neon.rSm)),
                ),
                child: Text(a, style: NeonType.manrope(NeonType.rowTitle, FontWeight.w600)),
              ),
              const SizedBox(height: 8),
            ],
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              child: Text('Not now', style: TextStyle(color: Neon.textLo)),
            ),
          ],
        ),
      ),
    );
  }
}

/// The number of things still to buy, beside Hub's Shopping list row.
class ShoppingCountBadge extends StatefulWidget {
  const ShoppingCountBadge({super.key});

  @override
  State<ShoppingCountBadge> createState() => _ShoppingCountBadgeState();
}

class _ShoppingCountBadgeState extends State<ShoppingCountBadge> {
  @override
  void initState() {
    super.initState();
    ShoppingService.instance.ensureLoaded();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ShoppingService.instance,
      builder: (context, _) {
        final n = ShoppingService.instance.toBuyCount;
        if (n == 0) return const SizedBox.shrink();
        return Semantics(
          label: '$n to buy',
          child: ExcludeSemantics(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
              decoration: BoxDecoration(
                color: Neon.violet.withValues(alpha: 0.13),
                borderRadius: BorderRadius.circular(Neon.rPill),
              ),
              // Plain ink at night, as the streak pill on Home.
              child: Text(
                '$n',
                style: NeonType.manrope(NeonType.caption, FontWeight.w700)
                    .copyWith(color: Neon.isDark ? Neon.textHi : Neon.violet),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Placeholder lines while a slow first load runs, breathing gently (the
/// look of Home's agenda skeleton); still with "Remove animations".
class _ListSkeleton extends StatefulWidget {
  const _ListSkeleton();

  @override
  State<_ListSkeleton> createState() => _ListSkeletonState();
}

class _ListSkeletonState extends State<_ListSkeleton> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
  late final Animation<double> _breath = Tween(begin: 0.45, end: 1.0).animate(_pulse);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (Motion.reduced(context)) {
      _pulse
        ..stop()
        ..value = 1.0;
    } else if (!_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  Widget _bar(double widthFactor, double height) => FractionallySizedBox(
        alignment: Alignment.centerLeft,
        widthFactor: widthFactor,
        child: Container(
          height: height,
          decoration: BoxDecoration(
            color: Neon.textDim.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(6),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Loading your shopping list',
      child: RepaintBoundary(
        child: FadeTransition(
          opacity: _breath,
          child: ListView(
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            children: [
              _bar(0.3, 12),
              const SizedBox(height: 12),
              for (final w in const [0.7, 0.5, 0.6, 0.45])
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 18),
                  decoration: BoxDecoration(
                    color: Neon.surfaceHigh,
                    borderRadius: BorderRadius.circular(Neon.rMd),
                    border: Border.all(color: Neon.line),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Neon.textDim.withValues(alpha: 0.35),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(child: _bar(w, 12)),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
