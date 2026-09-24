import 'dart:async';
import 'dart:math' as math;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../design/neon_tokens.dart';

/// How a message reads, and how long it may live.
enum FeedbackTone {
  info,
  success,
  error,

  /// "Opening…", "Calling Ravi…" — true only at the moment it is said.
  /// Never replayed when the app comes back to the foreground.
  progress,
}

/// ─────────────────────────────────────────────────────────────────────────
///  ONE PLACE FOR EVERY TOAST.
///
///  The owner's complaint (2026-09-24): "the toast repeats and is not
///  closed". Three things did that:
///   • every call QUEUED behind the last one, so a burst of five messages
///     covered the bottom of the screen for ~20 s and identical messages
///     played back to back;
///   • the Undo toasts never closed on their own (a SnackBar with an
///     action defaults to persist: true), so everything behind them
///     waited until the user found the swipe;
///   • ~40 screens called ScaffoldMessenger directly, each with its own
///     look and no policy at all.
///
///  Now every message in the app comes through here, and the rules are:
///   1. One slot. A new message replaces the one on screen; nothing queues.
///   2. No repeats. The same text within 5 s is shown once.
///   3. Always closes. Timed by length (3–6 s, errors 5 s), and every toast
///      has a ✕.
///   4. Never stale. While the app is in the background, or a sheet or
///      dialog covers the screen, a message waits (latest wins) and is
///      shown when it can actually be seen — or dropped if it is old or
///      was only ever a progress note.
///   5. Never on top of the voice screen's text box: while a session is on
///      screen the toast is lifted clear of it, and anything the assistant
///      also SAYS is not repeated as a toast (the caption already shows it).
/// ─────────────────────────────────────────────────────────────────────────
class AppFeedback {
  AppFeedback._();

  /// Wired to MaterialApp.scaffoldMessengerKey — the fallback for messages
  /// from services that have no BuildContext.
  static final messengerKey = GlobalKey<ScaffoldMessengerState>();

  /// Wired to MaterialApp.navigatorObservers: knows when a sheet or dialog
  /// is covering the screen, and clears a toast that belonged to a page
  /// the user has just left.
  static final FeedbackRouteObserver observer = FeedbackRouteObserver._();

  /// True while a toast is on screen — cards that sit where toasts appear
  /// step up out of the way.
  static final ValueNotifier<bool> visible = ValueNotifier<bool>(false);

  /// Set by HomeShell: is the voice session on screen right now?
  static bool Function()? sessionVisible;

  /// Identical text inside this window is shown once.
  static const Duration dedupeWindow = Duration(seconds: 5);

  /// Extra bottom margin while the voice session is on screen: clears the
  /// session's text box (which sits right where a toast would land).
  static const double sessionLift = 72;

  /// The exact bottom margin that clears the session's text box, measured
  /// by the box itself (it grows to four lines). [sessionLift] until then.
  static double? sessionMargin;

  /// How far a card near the dock steps up while a toast is showing, until
  /// the toast has been measured ([reach]).
  static const double cardLift = 64;

  /// How far the toast on screen reaches up from the bottom of the space
  /// above the keyboard (dp), measured from the toast itself once it is
  /// laid out; 0 while there is none. A two-line toast is taller than
  /// [cardLift], and a fixed step left it over the bottom of the card.
  static final ValueNotifier<double> reach = ValueNotifier<double>(0);

  /// Fires when a toast comes, goes or is measured: what cards near the
  /// dock listen to.
  static final Listenable changes = Listenable.merge([visible, reach]);

  /// Where a card whose bottom edge would be [base] dp up from the bottom
  /// goes while a toast is up: just above the toast.
  static double clearOfToast(double base) {
    if (!visible.value) return base;
    final r = reach.value;
    return r > 0 ? math.max(base, r + 8) : base + cardLift;
  }

  /// The short form every service has always used. Same policy as [show].
  static void toast(String message,
          {FeedbackTone tone = FeedbackTone.info, bool spoken = false}) =>
      show(message, tone: tone, spoken: spoken);

  /// Shows [message] under the policy above.
  ///
  /// [context] — pass it from a screen: the toast then belongs to that
  /// screen's messenger (tests and nested apps keep working) and is never
  /// held back behind an Undo. [spoken] — the assistant says the same
  /// sentence aloud; skipped while the voice session is on screen.
  static void show(
    String message, {
    BuildContext? context,
    FeedbackTone? tone,
    bool spoken = false,
  }) {
    final text = message.trim();
    if (text.isEmpty) return;
    if (spoken && _sessionOnScreen) return;
    final messenger = _messengerFor(context);
    if (messenger == null) return;
    final msg = _Message(
      text,
      tone ?? _inferTone(text),
      messenger,
      fromScreen: context != null,
      coveredByPopup: context != null &&
          context.mounted &&
          _coveredByPopup(context, messenger),
    );
    if (_mustWait(msg)) {
      _park(msg);
      return;
    }
    _present(msg);
  }

  /// A toast with an Undo button. Completes when it closes; the caller
  /// commits the change unless the reason is [SnackBarClosedReason.action].
  /// With nowhere to show it, completes at once (the change just commits).
  static Future<SnackBarClosedReason> showUndo(
    BuildContext context,
    String message, {
    required VoidCallback onUndo,
  }) {
    final messenger = _messengerFor(context);
    if (messenger == null) {
      return Future.value(SnackBarClosedReason.remove);
    }
    final msg = _Message(message.trim(), FeedbackTone.success, messenger,
        fromScreen: true, onUndo: onUndo);
    return _present(msg, force: true) ??
        Future.value(SnackBarClosedReason.remove);
  }

  /// "Copied". Android 13+ already confirms every copy itself, so a toast
  /// on top of that would be a second confirmation of the same thing.
  static Future<void> copied(BuildContext context,
      [String message = 'Copied']) async {
    if (await _systemConfirmsCopies()) return;
    if (!context.mounted) return;
    show(message, context: context, tone: FeedbackTone.success);
  }

  /// Takes the toast on screen away (a tab switch, a page change).
  static void dismiss() {
    final m = _current?.messenger;
    if (m == null || !m.mounted) return;
    m.hideCurrentSnackBar();
  }

  /// The voice session has just opened over the page (HomeShell calls
  /// this). A toast already up was placed for the page, right where the
  /// session's text box now sits: it is shown again at the session's
  /// height. An Undo belonged to the page now covered: it closes, and its
  /// change goes through, as on a tab switch.
  static void sessionOpened() {
    // Never re-show in the middle of a build (the engine can notify then).
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => sessionOpened());
      return;
    }
    final c = _current;
    if (c == null || !c.messenger.mounted) return;
    if (c.msg.onUndo != null) {
      dismiss();
      return;
    }
    _present(c.msg, force: true);
  }

  /// Is the toast on screen one with an Undo? A session opening closes
  /// those at once; the others move once the session is in (HomeShell).
  static bool get showingUndo => _current?.msg.onUndo != null;

  /// Test hook: forget everything between tests.
  @visibleForTesting
  static void resetForTest() {
    _current = null;
    _pending = null;
    _lastKey = null;
    _lastAt = DateTime(0);
    _lastClosedByUser = false;
    sessionVisible = null;
    sessionMargin = null;
    visible.value = false;
    reach.value = 0;
    observer._popups.clear();
  }

  /* ---------------------------------------------------------------- */

  static _Shown? _current;
  static _Message? _pending;
  static String? _lastKey;
  static DateTime _lastAt = DateTime(0);
  static bool _lastClosedByUser = false;
  static AppLifecycleListener? _lifecycle;
  static int? _sdkInt;

  static bool get _sessionOnScreen {
    try {
      return sessionVisible?.call() ?? false;
    } catch (_) {
      return false;
    }
  }

  static bool get _foreground {
    final s = WidgetsBinding.instance.lifecycleState;
    return s == null ||
        s == AppLifecycleState.resumed ||
        s == AppLifecycleState.inactive;
  }

  static ScaffoldMessengerState? _messengerFor(BuildContext? context) {
    if (context != null && context.mounted) {
      final m = ScaffoldMessenger.maybeOf(context);
      if (m != null) return m;
    }
    return messengerKey.currentState;
  }

  /// A screen's message raised from inside a sheet or dialog would land
  /// on the page BEHIND it — under the barrier, unseen, timing out.
  static bool _coveredByPopup(
      BuildContext context, ScaffoldMessengerState messenger) {
    final here = ModalRoute.of(context);
    if (here is! PopupRoute) return false;
    return ModalRoute.of(messenger.context) != here;
  }

  static bool _mustWait(_Message msg) {
    if (!_foreground) return true;
    if (msg.coveredByPopup) return observer.popupOpen;
    if (!msg.fromScreen) {
      if (observer.popupOpen) return true;
      // An Undo the user may still want is not swept away by a message
      // from the background — that one waits its turn (just one: latest).
      final c = _current;
      if (c != null &&
          c.msg.onUndo != null &&
          DateTime.now().difference(c.at) < const Duration(seconds: 4)) {
        return true;
      }
    }
    return false;
  }

  static void _park(_Message msg) {
    msg.parkedInBackground = !_foreground;
    _pending = msg; // latest wins
    _lifecycle ??= AppLifecycleListener(onResume: _onResume);
  }

  static void _onResume() {
    // A progress note on screen when the user left ("Calling Ravi…") is
    // over by now.
    final c = _current;
    if (c != null && c.msg.tone == FeedbackTone.progress) dismiss();
    _flushSoon();
  }

  static void _flushSoon() {
    if (_pending == null) return;
    Timer(Duration.zero, _flush);
  }

  static void _flush() {
    final p = _pending;
    if (p == null || _mustWait(p)) return;
    _pending = null;
    final age = DateTime.now().difference(p.at);
    if (p.tone == FeedbackTone.progress &&
        (p.parkedInBackground || age > const Duration(seconds: 3))) {
      return;
    }
    if (age > const Duration(seconds: 10)) return;
    if (!p.messenger.mounted) {
      final root = messengerKey.currentState;
      if (root == null) return;
      p.messenger = root;
    }
    _present(p);
  }

  static Future<SnackBarClosedReason>? _present(_Message msg,
      {bool force = false}) {
    final m = msg.messenger;
    if (!m.mounted) return null;
    final key = msg.text.toLowerCase();
    final now = DateTime.now();
    if (!force &&
        key == _lastKey &&
        now.difference(_lastAt) < dedupeWindow &&
        !_lastClosedByUser) {
      return null; // shown a moment ago — once is enough
    }
    // Still on screen (a long message lives 6 s, past the window above):
    // showing it again would only restart it — the "it repeats" effect.
    final up = _current;
    if (!force &&
        up != null &&
        up.msg.onUndo == null &&
        up.msg.text.toLowerCase() == key) {
      return null;
    }
    // ONE SLOT: whatever is showing (or queued) goes, without waiting for
    // its exit animation, so a burst never piles up behind it.
    m.clearSnackBars();
    m.removeCurrentSnackBar();
    final other = _current?.messenger;
    if (other != null && other != m && other.mounted) {
      other.removeCurrentSnackBar();
    }
    final controller = m.showSnackBar(_bar(msg));
    final shown = _Shown(msg, controller, now);
    _current = shown;
    _lastKey = key;
    _lastAt = now;
    _lastClosedByUser = false;
    _setVisible(true);
    // Watches for the return to the foreground from the first toast on:
    // a progress note left on screen by another app opening ("Opening…")
    // is cleared then.
    _lifecycle ??= AppLifecycleListener(onResume: _onResume);
    controller.closed.then((reason) {
      if (identical(_current, shown)) {
        _current = null;
        _setVisible(false);
      }
      if (_lastKey == key &&
          (reason == SnackBarClosedReason.dismiss ||
              reason == SnackBarClosedReason.swipe)) {
        _lastClosedByUser = true; // asked again after a ✕: show it again
      }
      _flushSoon();
    });
    return controller.closed;
  }

  static void _setVisible(bool v) {
    if (visible.value == v) return;
    // Never notify in the middle of a build.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        final now = _current != null;
        if (visible.value != now) visible.value = now;
        if (!now) reach.value = 0;
      });
      return;
    }
    visible.value = v;
    if (!v) reach.value = 0;
  }

  static Duration _durationFor(_Message msg) {
    if (msg.onUndo != null) return const Duration(seconds: 4);
    if (msg.tone == FeedbackTone.error) return const Duration(seconds: 5);
    if (msg.tone == FeedbackTone.progress) return const Duration(seconds: 3);
    final ms = 2500 + 40 * msg.text.length;
    return Duration(milliseconds: ms.clamp(3000, 6000));
  }

  /// "Couldn't…", "…failed…" read as errors without every caller saying so.
  static final _failure = RegExp(
    r"^(couldn[’']t|could not|can[’']t|cannot|failed|unable|"
    r"something went wrong|no contact|that didn[’']t)|\bfailed\b|"
    r"isn[’']t installed",
    caseSensitive: false,
  );

  static FeedbackTone _inferTone(String text) =>
      _failure.hasMatch(text) ? FeedbackTone.error : FeedbackTone.info;

  static SnackBar _bar(_Message msg) {
    final bottom = _sessionOnScreen ? (sessionMargin ?? 10 + sessionLift) : 10.0;
    final (IconData icon, Color tint) = switch (msg.tone) {
      FeedbackTone.success => (Icons.check_circle_rounded, Neon.success),
      FeedbackTone.error => (Icons.error_outline_rounded, Neon.error),
      FeedbackTone.progress => (Icons.hourglass_top_rounded, Neon.violet),
      FeedbackTone.info => (Icons.info_outline_rounded, Neon.violet),
    };
    return SnackBar(
      behavior: SnackBarBehavior.floating,
      // A SnackBar with an action defaults to persist: true — it would
      // never close on its own. Every toast here closes.
      persist: false,
      showCloseIcon: true,
      closeIconColor: Neon.textLo,
      backgroundColor: Neon.surfaceHigh,
      dismissDirection: DismissDirection.horizontal,
      margin: EdgeInsets.fromLTRB(16, 5, 16, bottom),
      duration: _durationFor(msg),
      content: _MeasureToast(
          child: Row(
        children: [
          Icon(icon, size: 18, color: tint),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              msg.text,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: Neon.textHi, fontSize: 14, height: 1.35),
            ),
          ),
        ],
      )),
      action: msg.onUndo == null
          ? null
          : SnackBarAction(
              label: 'Undo',
              textColor: Neon.violet,
              onPressed: msg.onUndo!,
            ),
    );
  }

  static Future<bool> _systemConfirmsCopies() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return false;
    }
    if (_sdkInt == null) {
      try {
        _sdkInt = (await DeviceInfoPlugin().androidInfo).version.sdkInt;
      } catch (_) {
        _sdkInt = 0;
      }
    }
    return (_sdkInt ?? 0) >= 33;
  }

  /// A page was pushed or popped: a toast that belonged to the page the
  /// user just left must not follow them (the messenger is app-wide, so
  /// it would). A toast raised in the same moment — "Saved", then pop —
  /// is kept.
  static void _onPageChange() {
    final c = _current;
    if (c == null) return;
    if (DateTime.now().difference(c.at) < const Duration(milliseconds: 800)) {
      return;
    }
    dismiss();
  }
}

/// Reports how far up the toast it sits in reaches ([AppFeedback.reach]),
/// so cards near the dock can stand just above it.
class _MeasureToast extends StatefulWidget {
  const _MeasureToast({required this.child});
  final Widget child;

  @override
  State<_MeasureToast> createState() => _MeasureToastState();
}

class _MeasureToastState extends State<_MeasureToast> {
  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
    return widget.child;
  }

  void _measure() {
    if (!mounted || !AppFeedback.visible.value) return;
    // The SnackBar's own surface: its top edge is the toast's top edge
    // (final from the first frame — the entrance only fades and clips).
    final surface = context.findAncestorStateOfType<State<Material>>();
    final box = surface?.context.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) return;
    final view = View.of(context);
    final bottom =
        (view.physicalSize.height - view.viewInsets.bottom) / view.devicePixelRatio;
    final r = bottom - box.localToGlobal(Offset.zero).dy;
    if (r > 0 && (AppFeedback.reach.value - r).abs() > 0.5) {
      AppFeedback.reach.value = r;
    }
  }
}

class _Message {
  _Message(this.text, this.tone, this.messenger,
      {this.fromScreen = false, this.coveredByPopup = false, this.onUndo})
      : at = DateTime.now();
  final String text;
  final FeedbackTone tone;
  ScaffoldMessengerState messenger;
  final bool fromScreen;
  final bool coveredByPopup;
  final VoidCallback? onUndo;
  final DateTime at;
  bool parkedInBackground = false;
}

class _Shown {
  _Shown(this.msg, this.controller, this.at);
  final _Message msg;
  final ScaffoldFeatureController<SnackBar, SnackBarClosedReason> controller;
  final DateTime at;
  ScaffoldMessengerState get messenger => msg.messenger;
}

/// Tracks sheets/dialogs on the root navigator, and page changes.
class FeedbackRouteObserver extends NavigatorObserver {
  FeedbackRouteObserver._();

  final Set<Route<dynamic>> _popups = <Route<dynamic>>{};

  /// A sheet, dialog or menu is covering the screen.
  bool get popupOpen {
    _popups.removeWhere((r) => !r.isActive);
    return _popups.isNotEmpty;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) {
      _popups.add(route);
    } else if (route is PageRoute && previousRoute != null) {
      AppFeedback._onPageChange();
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _left(route);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _left(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute != null) _popups.remove(oldRoute);
    if (newRoute is PopupRoute) {
      _popups.add(newRoute);
    } else if (newRoute is PageRoute) {
      AppFeedback._onPageChange();
    }
  }

  void _left(Route<dynamic> route) {
    if (_popups.remove(route)) {
      if (!popupOpen) AppFeedback._flushSoon();
      return;
    }
    if (route is PageRoute) AppFeedback._onPageChange();
  }
}
