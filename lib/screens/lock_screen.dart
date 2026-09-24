import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/app_lock.dart';

/// F1 — the gate shown while [AppLock.shouldLock] is true. Fires the
/// biometric prompt immediately on open; a 4-digit PIN pad is always
/// available underneath. Nothing else in the app renders until unlock.
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
