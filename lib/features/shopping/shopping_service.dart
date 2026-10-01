import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/log.dart';
import '../../services/api_service.dart';
import '../../services/auth_service.dart';
import 'shop_handoff.dart';
import 'shopping_models.dart';
import 'shopping_parse.dart';

/// What the server answered: the HTTP status (0 = never reached it) and
/// its JSON body. /shopping answers a success with its data and a refusal
/// with {ok:false, error, message}.
class ShoppingReply {
  const ShoppingReply(this.status, this.json);
  final int status;
  final Map<String, dynamic>? json;
  bool get ok => status >= 200 && status < 300 && json != null && json!['ok'] != false;
  String? get error => json?['error'] as String?;
  String? get message => json?['message'] as String?;
}

/// Sends one request to /shopping{path}. Replaced in tests. Never throws:
/// no connection is status 0.
typedef ShoppingTransport = Future<ShoppingReply> Function(String method, String path,
    {Map<String, dynamic>? body});

/// How a change went. [error] is a line for the user; [canRetry] when the
/// same request may simply work a moment later (no connection, a hiccup).
class ShoppingResult {
  const ShoppingResult.ok({this.merged, this.added})
      : ok = true,
        error = null,
        canRetry = false;
  const ShoppingResult.failed(String this.error, {this.canRetry = true})
      : ok = false,
        merged = null,
        added = null;

  final bool ok;
  final String? error;
  final bool canRetry;

  /// An add that went onto a line already there ("Milk — now 2 L").
  final ShoppingItem? merged;

  /// An add that made a new line (with the kind the server gave it).
  final ShoppingItem? added;
}

/// "Shop these": the hand-off to run, or the one question to ask first.
class HandoffReply {
  const HandoffReply({
    this.handoff,
    this.summary = '',
    this.needsGroceryApp = const [],
    this.groceryApps = const [],
    this.rememberedGroceryApp,
    this.error,
    this.canRetry = false,
  });

  final ShopHandoff? handoff;
  final String summary;

  /// Grocery things with no app to go to yet: ask which app, once.
  final List<String> needsGroceryApp;

  /// The grocery apps to offer ("Blinkit", "Zepto", …).
  final List<String> groceryApps;

  /// The app they just named, now remembered by the server.
  final String? rememberedGroceryApp;
  final String? error;
  final bool canRetry;

  static List<String> _names(Object? v) =>
      [for (final x in (v as List?) ?? const []) if ('$x'.trim().isNotEmpty) '$x'.trim()];

  factory HandoffReply.fromJson(Map<String, dynamic> j) => HandoffReply(
        handoff: ShopHandoff.fromJson(j['handoff']),
        summary: (j['summary'] ?? '').toString(),
        needsGroceryApp: _names(j['needsGroceryApp']),
        groceryApps: _names(j['groceryApps']),
        rememberedGroceryApp: (j['rememberedGroceryApp'] as String?)?.trim().isEmpty ?? true
            ? null
            : (j['rememberedGroceryApp'] as String).trim(),
      );
}

/// A removal shown at once and sent when its Undo toast has closed.
class PendingRemoval {
  PendingRemoval._(this._svc, this._ids, this._send);
  final ShoppingService _svc;
  final Set<int> _ids;
  final Future<ShoppingReply> Function() _send;
  bool _settled = false;

  /// Undo: the lines come back.
  void cancel() {
    if (_settled) return;
    _settled = true;
    _svc._unhide(_ids);
  }

  /// No Undo: the server is told.
  Future<ShoppingResult> commit() async {
    if (_settled) return const ShoppingResult.ok();
    _settled = true;
    return _svc._commitRemoval(_ids, _send);
  }
}

/// ─────────────────────────────────────────────────────────────────────────
///  THE SHOPPING LIST (build 124) — one list for anything to buy, kept by
///  the server (/shopping) and filled from any conversation ("add this to
///  my shopping list") as well as from the list screen.
///
///   * OPTIMISTIC. A tap changes the screen at once; the request follows.
///     If the server says no, or cannot be reached, the change is taken
///     back and the caller gets a line to show (with Try again).
///   * IN ORDER. Requests go out one at a time, in the order they were
///     made, so a quick tick-untick never lands the other way round; a
///     read that started before an edit never paints over it.
///   * KEPT. The last list is saved, so the screen opens at once and still
///     shows something offline; it is forgotten on sign-out.
///   * FOLLOWS THE ASSISTANT. A voice change sends shopping_list_updated,
///     and the engine calls [refresh].
/// ─────────────────────────────────────────────────────────────────────────
class ShoppingService extends ChangeNotifier {
  ShoppingService._() {
    AuthService.instance.onSignOut(reset);
  }
  static final ShoppingService instance = ShoppingService._();

  static const cacheKey = 'shopping_cache_v1';

  /// How requests reach the server (tests swap in their own).
  static ShoppingTransport transport = _http;

  List<ShoppingItem> _items = const [];
  List<ShoppingCategory> _categories = shoppingCategories;
  final Set<int> _hidden = {};
  int _nextTemp = -1;
  int _generation = 0;

  /// There is a list to show (saved or from the server).
  bool loaded = false;

  /// The last fetch failed (with [loaded]: offline, showing the saved list).
  bool failed = false;

  bool _hydrated = false;
  final List<Future<void> Function()> _queue = [];
  bool _draining = false;
  int _writes = 0;
  bool _refreshAfterWrites = false;
  bool _fetching = false;
  bool _fetchAgain = false;

  /// Every line, bought or not, as it should look now.
  List<ShoppingItem> get items =>
      _hidden.isEmpty ? _items : [for (final i in _items) if (!_hidden.contains(i.id)) i];

  /// The kinds, in the server's order and words.
  List<ShoppingCategory> get categories => _categories;

  String labelOf(String id) {
    for (final c in _categories) {
      if (c.id == id) return c.label;
    }
    for (final c in shoppingCategories) {
      if (c.id == id) return c.label;
    }
    return 'Other';
  }

  /// Things still to buy (for Hub).
  int get toBuyCount => items.where((i) => !i.checked).length;

  /// Shows [list] as if the server had just sent it (tests and screenshots).
  @visibleForTesting
  void debugSeed(List<ShoppingItem>? list, {bool failed = false}) {
    _items = list ?? const [];
    _hidden.clear();
    loaded = list != null;
    this.failed = failed;
    _hydrated = true;
    notifyListeners();
  }

  /// Forget the list (sign-out, tests).
  Future<void> reset() async {
    _generation++;
    _items = const [];
    _categories = shoppingCategories;
    _hidden.clear();
    loaded = false;
    failed = false;
    _hydrated = false;
    _writes = 0;
    _refreshAfterWrites = false;
    _fetching = false;
    _fetchAgain = false;
    _inFlight = null;
    _queue.clear();
    _draining = false;
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove(cacheKey);
    } catch (e) {
      AppLog.add('shop', 'could not forget the saved list: $e');
    }
  }

  /// The saved copy first (instant), then the server.
  Future<void> load() async {
    await _hydrate();
    await refresh();
  }

  /// [load], once — for places that only show a count (Hub).
  void ensureLoaded() {
    if (loaded || _fetching) return;
    unawaited(load());
  }

  Future<void> _hydrate() async {
    if (_hydrated) return;
    _hydrated = true;
    final gen = _generation;
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(cacheKey);
      if (raw == null || gen != _generation || loaded) return;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      _items = ShoppingItem.listFrom(j['items']);
      _categories = _categoriesFrom(j['categories']) ?? shoppingCategories;
      loaded = true;
      notifyListeners();
    } catch (e) {
      AppLog.add('shop', 'saved list unreadable: $e');
    }
  }

  Future<void> _save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(
          cacheKey,
          jsonEncode({
            'items': [for (final i in _items) if (!i.pending) i.toJson()],
            'categories': [for (final c in _categories) c.toJson()],
          }));
    } catch (e) {
      AppLog.add('shop', 'could not save the list: $e');
    }
  }

  static List<ShoppingCategory>? _categoriesFrom(Object? raw) {
    if (raw is! List) return null;
    final out = [
      for (final c in raw)
        if (ShoppingCategory.fromJson(c) case final cat?) cat,
    ];
    return out.isEmpty ? null : out;
  }

  // ---------------------------------------------------------------- order

  /// One request at a time, in the order asked.
  Future<T> _serial<T>(Future<T> Function() job) {
    final done = Completer<T>();
    _queue.add(() async {
      try {
        done.complete(await job());
      } catch (e, s) {
        done.completeError(e, s);
      }
    });
    if (!_draining) unawaited(_drain());
    return done.future;
  }

  Future<void> _drain() async {
    _draining = true;
    try {
      while (_queue.isNotEmpty) {
        await _queue.removeAt(0)();
      }
    } finally {
      _draining = false;
    }
  }

  /// A change, in its place in the queue. While any is waiting, a read's
  /// answer is older than the screen and is not painted.
  Future<ShoppingReply> _write(String method, String path, {Map<String, dynamic>? body}) {
    _writes++;
    return _serial(() => transport(method, path, body: body)).whenComplete(() {
      _writes--;
      if (_writes == 0 && _refreshAfterWrites) {
        _refreshAfterWrites = false;
        unawaited(refresh());
      }
    });
  }

  /// The list from the server. A second call while one is on its way asks
  /// again once it lands (the assistant may have changed it meanwhile), and
  /// completes with it — a pull-to-refresh spins until the list is in.
  Future<void> refresh() {
    final running = _inFlight;
    if (running != null) {
      _fetchAgain = true;
      return running;
    }
    return _inFlight = _fetchLoop();
  }

  Future<void>? _inFlight;

  Future<void> _fetchLoop() async {
    _fetching = true;
    try {
      do {
        _fetchAgain = false;
        final gen = _generation;
        final r = await _serial(() => transport('GET', ''));
        if (gen != _generation) return;
        if (!r.ok) {
          failed = true;
          notifyListeners();
          continue;
        }
        if (_writes > 0) {
          _refreshAfterWrites = true;
          continue;
        }
        _applyList(r.json!);
        loaded = true;
        failed = false;
        notifyListeners();
        unawaited(_save());
      } while (_fetchAgain);
    } finally {
      // Before this future completes: a refresh asked for from here on
      // starts a new read rather than joining one that has finished.
      _fetching = false;
      _inFlight = null;
    }
  }

  void _applyList(Map<String, dynamic> j) {
    final pending = [for (final i in _items) if (i.pending) i];
    _items = [...pending, ...ShoppingItem.listFrom(j['items'])];
    _categories = _categoriesFrom(j['categories']) ?? _categories;
  }

  void _replace(int id, ShoppingItem Function(ShoppingItem) change) {
    _items = [for (final i in _items) i.id == id ? change(i) : i];
  }

  ShoppingItem? byId(int id) {
    for (final i in _items) {
      if (i.id == id) return i;
    }
    return null;
  }

  // -------------------------------------------------------------- changes

  /// Adds one typed line. It shows at once (at the top, "Adding…") and
  /// takes its place in its category when the server has it.
  Future<ShoppingResult> add(ShoppingDraft d) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final temp = ShoppingItem(
      id: _nextTemp--,
      name: cleanItemName(d.name),
      quantity: d.quantity,
      unit: d.unit,
      amountText: amountTextOf(d.quantity, d.unit),
      createdAt: now,
      updatedAt: now,
    );
    final gen = _generation;
    _items = [temp, ..._items];
    notifyListeners();
    final r = await _write('POST', '/items', body: {
      'items': [d.toJson()],
      'source': 'manual',
    });
    if (gen != _generation) return const ShoppingResult.failed('Signed out.', canRetry: false);
    _items = [for (final i in _items) if (i.id != temp.id) i];
    if (!r.ok) {
      notifyListeners();
      return ShoppingResult.failed(lineFor(r), canRetry: retryable(r));
    }
    final j = r.json!;
    final added = ShoppingItem.listFrom(j['added']);
    final merged = ShoppingItem.listFrom(j['merged']);
    if (_writes == 0 && j['items'] is List) {
      _applyList(j);
    } else {
      for (final i in [...added, ...merged]) {
        if (byId(i.id) != null) {
          _replace(i.id, (_) => i);
        } else {
          _items = [..._items, i];
        }
      }
    }
    loaded = true;
    notifyListeners();
    unawaited(_save());
    return ShoppingResult.ok(
      merged: merged.isEmpty ? null : merged.first,
      added: added.isEmpty ? null : added.first,
    );
  }

  /// Ticks a line as bought (or back).
  Future<ShoppingResult> setChecked(ShoppingItem item, bool checked) => _patch(
        item,
        {'checked': checked},
        (i) => i.copyWith(checked: checked),
      );

  /// Changes a line from the edit sheet. [patch] holds only what changed:
  /// name, quantity, unit, details, link, store, note, category.
  Future<ShoppingResult> update(ShoppingItem item, Map<String, dynamic> patch) {
    if (patch.isEmpty) return Future.value(const ShoppingResult.ok());
    return _patch(item, patch, (i) {
      var out = i.copyWith(
        name: patch['name'] as String?,
        details: patch['details'] as String?,
        note: patch['note'] as String?,
        category: patch['category'] as String?,
      );
      if (patch.containsKey('link')) out = out.copyWith(link: patch['link'] as String?);
      if (patch.containsKey('store')) out = out.copyWith(store: patch['store'] as String?);
      if (patch.containsKey('quantity') || patch.containsKey('unit')) {
        final q = patch.containsKey('quantity')
            ? (patch['quantity'] as num?)?.toDouble()
            : out.quantity;
        final u = patch.containsKey('unit') ? patch['unit'] as String? : out.unit;
        out = out.copyWith(quantity: q, unit: u, amountText: amountTextOf(q, u));
      }
      return out;
    });
  }

  Future<ShoppingResult> _patch(ShoppingItem item, Map<String, dynamic> body,
      ShoppingItem Function(ShoppingItem) change) async {
    if (item.pending) {
      return const ShoppingResult.failed('One moment — it is still being added.', canRetry: false);
    }
    final before = byId(item.id);
    if (before == null) {
      return const ShoppingResult.failed("That's no longer on your list.", canRetry: false);
    }
    final gen = _generation;
    _replace(item.id, change);
    notifyListeners();
    final r = await _write('PATCH', '/items/${item.id}', body: body);
    if (gen != _generation) return const ShoppingResult.failed('Signed out.', canRetry: false);
    if (r.status == 404) {
      _items = [for (final i in _items) if (i.id != item.id) i];
      notifyListeners();
      unawaited(_save());
      return const ShoppingResult.failed("That's no longer on your list.", canRetry: false);
    }
    if (!r.ok) {
      _replace(item.id, (_) => before);
      notifyListeners();
      return ShoppingResult.failed(lineFor(r), canRetry: retryable(r));
    }
    final fresh = ShoppingItem.fromJson(r.json!['item']);
    // Another change to the list is still on its way: its own answer
    // brings the final state, so this one is not painted over it.
    if (fresh != null && _writes == 0) _replace(item.id, (_) => fresh);
    notifyListeners();
    unawaited(_save());
    return const ShoppingResult.ok();
  }

  /// Removes a line from the screen now; [PendingRemoval.commit] tells the
  /// server (after the Undo toast), [PendingRemoval.cancel] brings it back.
  PendingRemoval removeLater(ShoppingItem item) {
    _hidden.add(item.id);
    notifyListeners();
    return PendingRemoval._(this, {item.id}, () => _write('DELETE', '/items/${item.id}'));
  }

  /// Clears the bought lines from the screen now (Undo, then commit).
  PendingRemoval clearBoughtLater() {
    final ids = {for (final i in _items) if (i.checked && !i.pending) i.id};
    _hidden.addAll(ids);
    notifyListeners();
    return PendingRemoval._(
        this, ids, () => _write('POST', '/clear', body: {'checkedOnly': true}));
  }

  void _unhide(Set<int> ids) {
    _hidden.removeAll(ids);
    notifyListeners();
  }

  Future<ShoppingResult> _commitRemoval(
      Set<int> ids, Future<ShoppingReply> Function() send) async {
    final gen = _generation;
    final r = await send();
    if (gen != _generation) return const ShoppingResult.ok();
    if (r.ok || r.status == 404) {
      _items = [for (final i in _items) if (!ids.contains(i.id)) i];
      _hidden.removeAll(ids);
      notifyListeners();
      unawaited(_save());
      return const ShoppingResult.ok();
    }
    _hidden.removeAll(ids);
    notifyListeners();
    return ShoppingResult.failed(lineFor(r), canRetry: retryable(r));
  }

  /// Sends a removal again after a failure (the Try again button).
  Future<ShoppingResult> retryRemove(ShoppingItem item) => removeLater(item).commit();

  /// Empties the whole list, bought or not (after the screen's own
  /// question). Shown at once; put back if the server cannot do it.
  Future<ShoppingResult> clearAll() async {
    final before = _items;
    final gen = _generation;
    _items = [for (final i in _items) if (i.pending) i];
    notifyListeners();
    final r = await _write('POST', '/clear', body: {'checkedOnly': false});
    if (gen != _generation) return const ShoppingResult.ok();
    if (!r.ok) {
      _items = before;
      notifyListeners();
      return ShoppingResult.failed(lineFor(r), canRetry: retryable(r));
    }
    unawaited(_save());
    return const ShoppingResult.ok();
  }

  /// The list as tidy text for WhatsApp (unticked lines only), or the
  /// reason it could not be had.
  Future<({String? text, String? error, bool canRetry})> shareText({String? category}) async {
    final q = category == null || category.isEmpty
        ? ''
        : '?category=${Uri.encodeQueryComponent(category)}';
    final r = await _serial(() => transport('GET', '/share-text$q'));
    if (!r.ok) return (text: null, error: lineFor(r), canRetry: retryable(r));
    return (text: (r.json!['text'] ?? '').toString().trim(), error: null, canRetry: false);
  }

  /// "Shop these": which app opens which line. [ids] limits it to those
  /// lines (default: everything not yet bought); [groceryApp] is the
  /// answer to "which app do you use for groceries?".
  Future<HandoffReply> handoff({List<int>? ids, String? groceryApp}) async {
    final r = await _serial(() => transport('POST', '/handoff', body: {
          if (ids != null && ids.isNotEmpty) 'ids': ids,
          if (groceryApp != null && groceryApp.isNotEmpty) 'groceryApp': groceryApp,
        }));
    if (!r.ok) {
      if (r.status == 404) unawaited(refresh());
      return HandoffReply(error: lineFor(r), canRetry: retryable(r));
    }
    return HandoffReply.fromJson(r.json!);
  }

  // --------------------------------------------------------------- words

  /// The same request may simply work a moment later.
  static bool retryable(ShoppingReply r) => r.status == 0 || r.status == 429 || r.status >= 500;

  /// A reply as a line for the user.
  static String lineFor(ShoppingReply r) {
    if (r.status == 0) return "Couldn't reach the server — check your connection.";
    if (r.status == 429) return 'Too many changes at once — wait a moment, then try again.';
    if (r.status >= 500) return 'Something went wrong on our side — try again.';
    switch (r.error) {
      case 'list_full':
        return 'Your list is full (300 things) — clear the bought ones first.';
      case 'name_required':
      case 'no_items':
        return 'Type what to buy — like “milk” or “2 kg onions”.';
      case 'name_too_long':
        return 'That name is too long — 80 letters at most.';
      case 'details_too_long':
        return 'The details can be 200 letters at most.';
      case 'note_too_long':
        return 'The note can be 200 letters at most.';
      case 'store_too_long':
        return 'The shop name can be 40 letters at most.';
      case 'bad_link':
        return 'The link has to be a web address starting with https://';
      case 'bad_quantity':
        return "That amount doesn't look right.";
      case 'bad_unit':
        return 'Try a unit like g, kg, ml, L, pcs or packet.';
      case 'bad_category':
        return "That isn't one of the list's kinds.";
      case 'not_found':
        return "That's no longer on your list.";
      case 'nothing_to_buy':
        return 'Nothing left to buy on the list.';
    }
    final m = r.message?.trim() ?? '';
    // The server's own sentence for a refusal it explained ("Google Pay
    // is a payment app — shopping lists open shopping apps only").
    if (r.status >= 400 && r.status < 500 && m.isNotEmpty) return m;
    return "Couldn't do that just now — try again.";
  }

  static final http.Client _client = http.Client();

  static Future<ShoppingReply> _http(String method, String path,
      {Map<String, dynamic>? body}) async {
    try {
      final req = http.Request(method, Uri.parse('${ApiService.baseUrl}/shopping$path'))
        ..headers.addAll(ApiService.authHeaders);
      if (body != null) req.body = jsonEncode(body);
      final res = await http.Response.fromStream(
          await _client.send(req).timeout(const Duration(seconds: 12)));
      ApiService.noteAuthStatus(res.statusCode);
      Map<String, dynamic>? json;
      try {
        final d = jsonDecode(res.body);
        if (d is Map<String, dynamic>) json = d;
      } catch (_) {
        // Not JSON (a proxy's error page): the status says enough.
      }
      return ShoppingReply(res.statusCode, json);
    } catch (e) {
      AppLog.add('shop', '$method /shopping$path failed: $e');
      return const ShoppingReply(0, null);
    }
  }
}
