import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/app_lock.dart';
import '../design/motion.dart';
import '../design/neon_tokens.dart';
import '../design/neon_widgets.dart';

/// THE LOCK SITS ABOVE EVERY SCREEN (audit, 2026-09-27). It used to be the
/// first route's child, so relocking covered only that route: Email, a
/// patient's case file or a screen opened by voice stayed on top of it,
/// readable and usable. MaterialApp.builder puts this layer over the
/// Navigator itself. While [locked] says so, everything under it is
/// hidden, unfocusable (a field's keyboard goes) and still, but kept: the
/// owner is back where they were after unlocking. It goes up instantly —
/// a lock that faded in would show private content under it — and fades
/// out on unlock.
class LockLayer extends StatelessWidget {
  const LockLayer({
    super.key,
    required this.locked,
    required this.changes,
    required this.child,
  });

  /// Whether the lock is up now; asked again whenever [changes] fires.
  final bool Function() locked;
  final Listenable changes;

  /// The app's Navigator (MaterialApp.builder's child).
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: changes,
      builder: (context, _) {
        final on = locked();
        return Stack(
          fit: StackFit.expand,
          children: [
            ExcludeFocus(
              excluding: on,
              child: TickerMode(
                enabled: !on,
                child: Offstage(offstage: on, child: child),
              ),
            ),
            AnimatedSwitcher(
              switchInCurve: Motion.easeEnter,
              switchOutCurve: Motion.easeFadeOut,
              duration: Duration.zero,
              reverseDuration: const Duration(milliseconds: 160),
              layoutBuilder: (current, previous) => Stack(
                fit: StackFit.expand,
                children: [...previous, if (current != null) current],
              ),
              // Its own messenger: under the app's, the lock's Scaffold
              // would show every toast the hidden screens raise — their
              // words, and an Undo that works — on top of the lock.
              child: on
                  ? const ScaffoldMessenger(child: LockScreen())
                  : const SizedBox.shrink(),
            ),
          ],
        );
      },
    );
  }
}

/// Back on the lock leaves the app, as it did when the lock was the first
/// screen, and never pops, unseen, the screens hidden under it. Added in
/// main() before runApp, so it is asked before the app's Navigator is.
class LockBackGuard with WidgetsBindingObserver {
  LockBackGuard(this.locked);

  final bool Function() locked;

  @override
  Future<bool> didPopRoute() async {
    if (!locked()) return false;
    await SystemNavigator.pop();
    return true;
  }
}

/// F1 — the gate shown while [AppLock.shouldLock] is true, above every
/// screen ([LockLayer]). Fires the biometric prompt immediately on open; a
/// 4-digit PIN pad is always available underneath. Nothing under it can be
/// seen or used until unlock.
class LockScreen extends StatefulWidget {
  const LockScreen({super.key});

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  String _pin = '';
  String? _error;
  bool _bioAvailable = false;

  @override
  void initState() {
    super.initState();
    _startBiometric();
  }

  Future<void> _startBiometric() async {
    final lock = AppLock.instance;
    _bioAvailable = await lock.deviceHasBiometrics();
    if (mounted) setState(() {});
    if (_bioAvailable && await lock.tryBiometric()) {
      lock.markUnlocked();
    }
  }

  Future<void> _tap(String d) async {
    HapticFeedback.selectionClick();
    if (_pin.length >= 4) return;
    setState(() {
      _pin += d;
      _error = null;
    });
    if (_pin.length == 4) {
      final ok = await AppLock.instance.tryPin(_pin);
      if (ok) {
        AppLock.instance.markUnlocked();
      } else if (mounted) {
        HapticFeedback.heavyImpact();
        setState(() {
          _pin = '';
          _error = 'Wrong PIN — try again';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Under the app's sky, the lock lit in the brand's light and the dots
    // glowing as they fill (2026-09-30); it was a plain theme page.
    return NeonScaffold(
      body: SafeArea(
        child: Center(
          // Scrolls when the keyboard (left up by another app) leaves too
          // little room for the pad.
          child: SingleChildScrollView(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: Neon.halo(Neon.violet, strength: 0.8),
                    ),
                    child: Icon(Icons.lock_outline_rounded,
                        size: 44, color: Neon.violet),
                  ),
                  const SizedBox(height: 12),
                  Text('MyAssistant is locked',
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 20),
                  // PIN dots
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(4, (i) {
                      final filled = i < _pin.length;
                      return Container(
                        margin: const EdgeInsets.symmetric(horizontal: 8),
                        width: 14,
                        height: 14,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: filled ? Neon.cyan : Colors.transparent,
                          border: Border.all(color: Neon.cyan, width: 1.5),
                          boxShadow: filled
                              ? Neon.halo(Neon.cyan, strength: 0.6)
                              : null,
                        ),
                      );
                    }),
                  ),
                  SizedBox(
                    height: 28,
                    child: _error == null
                        ? null
                        : Center(
                            child: Text(_error!,
                                style: TextStyle(color: Neon.errorInk))),
                  ),
                  // Pad
                  for (final row in const [
                    ['1', '2', '3'],
                    ['4', '5', '6'],
                    ['7', '8', '9'],
                    ['', '0', '<'],
                  ])
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (final key in row)
                          Padding(
                            padding: const EdgeInsets.all(6),
                            child: SizedBox(
                              width: 72,
                              height: 56,
                              child: key.isEmpty
                                  ? null
                                  : key == '<'
                                      // Named for a screen reader through
                                      // the icon, not a tooltip: the lock
                                      // is drawn over the app, where there
                                      // is no Overlay for a tooltip.
                                      ? IconButton(
                                          onPressed: () => setState(() => _pin =
                                              _pin.isEmpty
                                                  ? _pin
                                                  : _pin.substring(
                                                      0, _pin.length - 1)),
                                          icon: const Icon(
                                              Icons.backspace_outlined,
                                              semanticLabel:
                                                  'Delete last digit'),
                                        )
                                      : OutlinedButton(
                                          onPressed: () => _tap(key),
                                          child: Text(key,
                                              style: const TextStyle(
                                                  fontSize: 20)),
                                        ),
                            ),
                          ),
                      ],
                    ),
                  if (_bioAvailable) ...[
                    const SizedBox(height: 8),
                    // The quick way in, lit as the cyan of a suggestion.
                    NeonPill(
                      onPressed: _startBiometric,
                      icon: Icons.fingerprint_rounded,
                      label: 'Use fingerprint / face',
                      tone: NeonTone.tip,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
