import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/log.dart';
import '../../services/auth_service.dart';
import '../../services/notification_service.dart';

/// One thing to buy in a hand-off: what it is and the link that finds it.
class ShopHandoffItem {
  const ShopHandoffItem({
    required this.id,
    required this.name,
    this.details = '',
    this.amountText = '',
    required this.url,
  });

  final int id;
  final String name;
  final String details;
  final String amountText;
  final String url;

  static ShopHandoffItem? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final name = (raw['name'] ?? '').toString().trim();
    final url = (raw['url'] ?? '').toString().trim();
    if (name.isEmpty || url.isEmpty) return null;
    return ShopHandoffItem(
      id: (raw['id'] as num?)?.toInt() ?? 0,
      name: name,
      details: (raw['details'] ?? '').toString(),
      amountText: (raw['amountText'] ?? '').toString(),
      url: url,
    );
  }

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'details': details, 'amountText': amountText, 'url': url};
}

/// The things one app opens: Blinkit for the groceries, Myntra for the kurti.
class ShopHandoffGroup {
  const ShopHandoffGroup({
    required this.app,
    required this.label,
    required this.pkg,
    required this.items,
  });

  final String app;

  /// "Blinkit", "Myntra" — or the website's name for a line with its own link.
  final String label;

  /// The Android package to open the links in; '' for the browser.
  final String pkg;
  final List<ShopHandoffItem> items;

  static ShopHandoffGroup? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final items = [
      for (final i in (raw['items'] as List?) ?? const [])
        if (ShopHandoffItem.fromJson(i) case final item?) item,
    ];
    if (items.isEmpty) return null;
    final label = (raw['label'] ?? '').toString().trim();
    return ShopHandoffGroup(
      app: (raw['app'] ?? '').toString(),
      label: label.startsWith('www.') ? label.substring(4) : label,
      pkg: (raw['pkg'] ?? '').toString().trim(),
      items: items,
    );
  }
}

/// ─────────────────────────────────────────────────────────────────────────
///  THE HAND-OFF (build 124): {type:"shop_handoff", groups:[{app, label,
///  pkg, items:[{id, name, details?, amountText, url}]}]} — the same shape
///  from the list's "Shop these" (POST /shopping/handoff) and from the
///  assistant's shop_from_list. Nothing is ordered or paid from here: each
///  thing opens in its shopping app, where the owner chooses and pays.
/// ─────────────────────────────────────────────────────────────────────────
class ShopHandoff {
  const ShopHandoff(this.groups);

  final List<ShopHandoffGroup> groups;

  /// Null unless [raw] is a shop_handoff with at least one thing in it.
  static ShopHandoff? fromJson(Object? raw) {
    if (raw is! Map || raw['type'] != 'shop_handoff') return null;
    final groups = [
      for (final g in (raw['groups'] as List?) ?? const [])
        if (ShopHandoffGroup.fromJson(g) case final group?) group,
    ];
    return groups.isEmpty ? null : ShopHandoff(groups);
  }

  int get total => groups.fold(0, (n, g) => n + g.items.length);
}

/// NEVER A PAYMENT APP. The server already refuses to send one; the phone
/// checks again, because what it opens is the phone's responsibility.
abstract final class ShopSafety {
  /// UPI, wallet and banking apps (the owner pays inside the shopping app).
  static const moneyPackages = {
    'com.google.android.apps.nbu.paisa.user', // Google Pay
    'com.phonepe.app',
    'net.one97.paytm',
    'in.org.npci.upiapp', // BHIM
    'com.dreamplug.androidapp', // CRED
    'com.mobikwik_new',
    'com.freecharge.android',
    'com.sbi.lotusintouch', // YONO
    'com.csam.icici.bank.imobile',
    'com.snapwork.hdfc',
    'com.axis.mobile',
    'money.super.payments', // super.money
    'com.bharatpe.app',
    'com.enstage.wibmo.hdfc', // PayZapp
    'com.paypal.android.p2pmobile',
  };

  static final _moneyHost = RegExp(
      r'(^|\.)(paytm\.(com|in|me)|phonepe\.com|pay\.google\.com|gpay\.app\.goo\.gl|cred\.club|'
      r'mobikwik\.com|freecharge\.in|bhimupi\.org\.in|npci\.org\.in|upi\.link)$',
      caseSensitive: false);

  static final _packageName = RegExp(r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$');

  /// This app's own package: never a target.
  static const ownPackage = 'com.myassistant.myassistant';

  /// An https page that is not a payment site.
  static bool safeUrl(String url) {
    if (url.length > 2048) return false;
    final u = Uri.tryParse(url);
    return u != null && u.scheme == 'https' && u.host.isNotEmpty && !_moneyHost.hasMatch(u.host);
  }

  /// A shopping app's package we may open a link in ('' = none).
  static String usablePackage(String pkg) {
    final p = pkg.trim();
    if (p.isEmpty || !_packageName.hasMatch(p)) return '';
    if (p == ownPackage || moneyPackages.contains(p)) return '';
    return p;
  }
}

/// `intent://…#Intent;scheme=https;package=…;end` — [url] opened by the
/// app [pkg] itself (hari/intent's launch). Null when either is unusable.
String? shopIntentUri(String url, String pkg) {
  if (!ShopSafety.safeUrl(url)) return null;
  final p = ShopSafety.usablePackage(pkg);
  if (p.isEmpty) return null;
  final rest = url.substring('https:'.length); // "//host/path?query"
  return 'intent:$rest#Intent;scheme=https;package=$p;action=android.intent.action.VIEW;end';
}

/// One stop on the trip: a thing, and where it opens.
class ShopStep {
  const ShopStep({required this.item, required this.label, required this.pkg});

  final ShopHandoffItem item;
  final String label;
  final String pkg;

  Map<String, dynamic> toJson() => {...item.toJson(), 'label': label, 'pkg': pkg};

  static ShopStep? fromJson(Object? raw) {
    final item = ShopHandoffItem.fromJson(raw);
    if (item == null || raw is! Map) return null;
    return ShopStep(
      item: item,
      label: (raw['label'] ?? '').toString(),
      pkg: (raw['pkg'] ?? '').toString(),
    );
  }
}

/// What the ongoing notification says: "Shopping · 1 of 7", "Next: curd".
class ShopProgress {
  const ShopProgress({
    required this.position,
    required this.total,
    required this.current,
    this.next,
  });

  final int position;
  final int total;
  final ShopStep current;
  final ShopStep? next;

  bool get hasNext => next != null;

  String get title => 'Shopping · $position of $total';

  String get body {
    final n = next;
    if (n == null) {
      return total == 1
          ? 'Tick it off in your list once you have bought it.'
          : "That's the last one — tick what you bought in your list.";
    }
    final elsewhere = n.label.isNotEmpty && n.label != current.label;
    return elsewhere ? 'Next: ${n.item.name} on ${n.label}' : 'Next: ${n.item.name}';
  }
}

/// How one thing was opened.
class ShopOpenResult {
  const ShopOpenResult({
    required this.opened,
    this.step,
    this.inApp = false,
    this.position = 0,
    this.total = 0,
    this.finished = false,
    this.skipped = 0,
  });

  /// Something is now open on the phone.
  final bool opened;
  final ShopStep? step;

  /// In the shopping app itself (not the browser).
  final bool inApp;
  final int position;
  final int total;

  /// There was nothing after the last one.
  final bool finished;

  /// Lines left out because they pointed somewhere unsafe.
  final int skipped;
}

/// What the runner needs from the phone (the real one below; fakes in tests).
abstract class ShopPorts {
  /// Opens [url] in the app [pkg]. False when it is not installed or does
  /// not take that link.
  Future<bool> openInApp(String url, String pkg);

  /// Opens [url] in the browser (or whichever app claims it).
  Future<bool> openInBrowser(String url);

  /// Shows (or updates) the "Shopping · 1 of 7" notification.
  Future<void> showProgress(ShopProgress p);

  /// Takes it away.
  Future<void> clearProgress();

  /// Is it still in the notification shade (not swiped away)?
  Future<bool> progressShown();
}

/// The phone's own hands: hari/intent's launch, url_launcher, and the
/// notification plumbing the reminders use.
class AppShopPorts implements ShopPorts {
  const AppShopPorts();

  static const _intent = MethodChannel('hari/intent');

  /// ANDROID LETS AN APP START ANOTHER ONLY WHILE IT IS ON SCREEN. The
  /// notification's Next brings this app to the front first (its action
  /// shows the app); the next thing opens once it is really there.
  static Future<void> _inFront() async {
    for (var i = 0; i < 40; i++) {
      final s = WidgetsBinding.instance.lifecycleState;
      if (s == null || s == AppLifecycleState.resumed) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    AppLog.add('shop', 'not in front after 2 s; opening anyway');
  }

  @override
  Future<bool> openInApp(String url, String pkg) async {
    final uri = shopIntentUri(url, pkg);
    if (uri == null) return false;
    await _inFront();
    try {
      return await _intent.invokeMethod<bool>('launch', {'uri': uri}) ?? false;
    } catch (e) {
      AppLog.add('shop', 'open in $pkg failed: $e');
      return false;
    }
  }

  @override
  Future<bool> openInBrowser(String url) async {
    if (!ShopSafety.safeUrl(url)) return false;
    await _inFront();
    try {
      return await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (e) {
      AppLog.add('shop', 'open failed: $e');
      return false;
    }
  }

  @override
  Future<void> showProgress(ShopProgress p) =>
      ReminderNotifications.instance.showShopping(p.title, p.body, hasNext: p.hasNext);

  @override
  Future<void> clearProgress() => ReminderNotifications.instance.cancelShopping();

  @override
  Future<bool> progressShown() => ReminderNotifications.instance.shoppingShown();
}

/// ─────────────────────────────────────────────────────────────────────────
///  THE SHOPPING TRIP. Opens the first thing (in its app when installed,
///  else the browser) and keeps a notification — "Shopping · 1 of 7 ·
///  Next: curd" — whose Next opens the following one; when one app's
///  things are done it moves on to the next app. The owner ticks things
///  off in the list as they buy them; Done ends the trip.
///
///  Kept across a restart (a tap on Next can start the app), for [ttl].
/// ─────────────────────────────────────────────────────────────────────────
class ShopHandoffRunner {
  ShopHandoffRunner._() {
    AuthService.instance.onSignOut(end);
  }
  static final ShopHandoffRunner instance = ShopHandoffRunner._();

  static const stateKey = 'shop_handoff_v1';

  /// A trip nobody has touched for this long is over.
  static const ttl = Duration(hours: 12);

  /// The phone's hands (tests swap in their own).
  static ShopPorts ports = const AppShopPorts();

  /// The phone's clock (tests pin it).
  static DateTime Function() clock = DateTime.now;

  List<ShopStep>? _steps;
  int _at = -1;
  DateTime? _touchedAt;
  bool _restored = false;
  final List<Future<void> Function()> _queue = [];
  bool _draining = false;

  /// One thing at a time: a double tap on Next opens one thing, not two.
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

  bool get _expired => _touchedAt == null || clock().difference(_touchedAt!) > ttl;

  /// A trip is under way.
  Future<bool> hasTrip() => _serial(() async {
        await _restore();
        return _steps != null && !_expired;
      });

  /// Starts a trip: opens the first thing and puts up the notification.
  Future<ShopOpenResult> start(ShopHandoff h) => _serial(() async {
        _restored = true;
        final steps = <ShopStep>[];
        var skipped = 0;
        for (final g in h.groups) {
          final pkg = ShopSafety.usablePackage(g.pkg);
          if (g.pkg.isNotEmpty && pkg.isEmpty) {
            AppLog.add('shop', 'not opening ${g.label} in ${g.pkg}');
          }
          for (final i in g.items) {
            if (!ShopSafety.safeUrl(i.url)) {
              skipped++;
              continue;
            }
            steps.add(ShopStep(item: i, label: g.label, pkg: pkg));
          }
        }
        if (skipped > 0) AppLog.add('shop', 'left out $skipped unsafe link(s)');
        if (steps.isEmpty) {
          await _clear();
          return ShopOpenResult(opened: false, skipped: skipped);
        }
        _steps = steps;
        _at = 0;
        _touchedAt = clock();
        final r = await _open(0, skipped: skipped);
        if (!r.opened) {
          await _clear();
          return r;
        }
        await _save();
        await _show();
        return r;
      });

  /// The notification's Next: the following thing.
  Future<ShopOpenResult> next() => _serial(() async {
        await _restore();
        final steps = _steps;
        if (steps == null || _expired) {
          await _clear();
          return const ShopOpenResult(opened: false);
        }
        _touchedAt = clock();
        if (_at + 1 >= steps.length) {
          await _save();
          await _show();
          return ShopOpenResult(
              opened: false, finished: true, position: _at + 1, total: steps.length);
        }
        final r = await _open(_at + 1);
        // Moved on either way: a link that will not open must not hold up
        // the rest of the list (the owner is told which one).
        _at++;
        await _save();
        await _show();
        return r;
      });

  /// Done (the notification's button, a new trip, or sign-out).
  Future<void> end() => _serial(_clear);

  /// The reminders' re-sync took every notification away: put this one
  /// back — unless the owner had swiped it away, which ends the trip.
  Future<void> rearm({required bool stillShown}) => _serial(() async {
        await _restore();
        if (_steps == null) return;
        if (!stillShown || _expired) {
          await _clear();
          return;
        }
        await _show();
      });

  Future<ShopOpenResult> _open(int at, {int skipped = 0}) async {
    final steps = _steps!;
    final s = steps[at];
    var inApp = false;
    var opened = false;
    if (s.pkg.isNotEmpty) {
      inApp = await ports.openInApp(s.item.url, s.pkg);
      opened = inApp;
    }
    if (!opened) opened = await ports.openInBrowser(s.item.url);
    AppLog.add('shop',
        '${at + 1}/${steps.length} ${opened ? (inApp ? 'opened in ${s.label}' : 'opened in the browser') : 'did NOT open'}');
    return ShopOpenResult(
      opened: opened,
      step: s,
      inApp: inApp,
      position: at + 1,
      total: steps.length,
      skipped: skipped,
    );
  }

  Future<void> _show() async {
    final steps = _steps;
    if (steps == null || _at < 0 || _at >= steps.length) return;
    try {
      await ports.showProgress(ShopProgress(
        position: _at + 1,
        total: steps.length,
        current: steps[_at],
        next: _at + 1 < steps.length ? steps[_at + 1] : null,
      ));
    } catch (e) {
      AppLog.add('shop', 'notification failed: $e');
    }
  }

  Future<void> _clear() async {
    _steps = null;
    _at = -1;
    _touchedAt = null;
    _restored = true;
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove(stateKey);
    } catch (e) {
      AppLog.add('shop', 'could not forget the trip: $e');
    }
    try {
      await ports.clearProgress();
    } catch (e) {
      AppLog.add('shop', 'could not clear the notification: $e');
    }
  }

  Future<void> _save() async {
    final steps = _steps;
    if (steps == null) return;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(
          stateKey,
          jsonEncode({
            'steps': [for (final s in steps) s.toJson()],
            'at': _at,
            'touchedAt': _touchedAt?.millisecondsSinceEpoch,
          }));
    } catch (e) {
      AppLog.add('shop', 'could not keep the trip: $e');
    }
  }

  Future<void> _restore() async {
    if (_restored) return;
    _restored = true;
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(stateKey);
      if (raw == null) return;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final steps = [
        for (final s in (j['steps'] as List?) ?? const [])
          if (ShopStep.fromJson(s) case final step?) step,
      ];
      final at = (j['at'] as num?)?.toInt() ?? -1;
      final touched = (j['touchedAt'] as num?)?.toInt();
      if (steps.isEmpty || at < 0 || at >= steps.length || touched == null) return;
      _steps = steps;
      _at = at;
      _touchedAt = DateTime.fromMillisecondsSinceEpoch(touched);
    } catch (e) {
      AppLog.add('shop', 'saved trip unreadable: $e');
    }
  }

  /// Forget everything (tests).
  @visibleForTesting
  Future<void> reset() async {
    _queue.clear();
    _draining = false;
    _steps = null;
    _at = -1;
    _touchedAt = null;
    _restored = false;
    final p = await SharedPreferences.getInstance();
    await p.remove(stateKey);
  }

  /// Reads the saved trip again, as a fresh start of the app would (tests).
  @visibleForTesting
  void forgetInMemory() {
    _steps = null;
    _at = -1;
    _touchedAt = null;
    _restored = false;
  }
}
