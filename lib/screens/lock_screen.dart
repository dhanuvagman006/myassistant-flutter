import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/app_lock.dart';

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
              duration: Duration.zero,
              reverseDuration: const Duration(milliseconds: 160),
              layoutBuilder: (current, previous) => Stack(
                fit: StackFit.expand,
                children: [...previous, if (current != null) current],
              ),
              child: on ? const LockScreen() : const SizedBox.shrink(),
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
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
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
                Icon(Icons.lock_outline_rounded, size: 44, color: cs.primary),
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
                        color: filled ? cs.primary : Colors.transparent,
                        border: Border.all(color: cs.primary, width: 1.5),
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
                              style: TextStyle(color: cs.error))),
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
                                    ? IconButton(
                                        onPressed: () => setState(() => _pin =
                                            _pin.isEmpty
                                                ? _pin
                                                : _pin.substring(
                                                    0, _pin.length - 1)),
                                        icon: const Icon(
                                            Icons.backspace_outlined),
                                      )
                                    : OutlinedButton(
                                        onPressed: () => _tap(key),
                                        child: Text(key,
                                            style:
                                                const TextStyle(fontSize: 20)),
                                      ),
                          ),
                        ),
                    ],
                  ),
                if (_bioAvailable)
                  TextButton.icon(
                    onPressed: _startBiometric,
                    icon: const Icon(Icons.fingerprint_rounded),
                    label: const Text('Use fingerprint / face'),
                  ),
              ],
            ),
          ),
          ),
        ),
      ),
    );
  }
}
