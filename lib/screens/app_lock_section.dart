import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/apple_kit.dart';
import '../design/neon_tokens.dart';
import '../services/app_lock.dart';

/// PRIVACY & SECURITY — the app lock's switch.
///
/// AppLock and LockScreen were built (fingerprint / face, 4-digit PIN as the
/// fallback) but nothing ever turned them on: no row existed. Owner's pick,
/// 2026-09-23 ("App lock with fingerprint").
class AppLockSection extends StatefulWidget {
  const AppLockSection({super.key});

  @override
  State<AppLockSection> createState() => _AppLockSectionState();
}

class _AppLockSectionState extends State<AppLockSection> {
  final _lock = AppLock.instance;

  @override
  void initState() {
    super.initState();
    _lock.addListener(_sync);
  }

  @override
  void dispose() {
    _lock.removeListener(_sync);
    super.dispose();
  }

  void _sync() {
    if (mounted) setState(() {});
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  /// Asks for a 4-digit PIN. [confirm] asks twice (setting a new one).
  Future<String?> _askPin({required String title, bool confirm = false}) async {
    Future<String?> once(String heading) => showDialog<String>(
          context: context,
          builder: (c) => _PinDialog(title: heading),
        );
    final first = await once(title);
    if (first == null || !confirm) return first;
    final again = await once('Enter it once more');
    if (again == null) return null;
    if (again != first) {
      _snack("The PINs didn't match — try again.");
      return null;
    }
    return first;
  }

  Future<void> _turnOn() async {
    final pin = await _askPin(title: 'Choose a 4-digit PIN', confirm: true);
    if (pin == null) return;
    // Fingerprint / face when the phone has it; the PIN is the fallback.
    if (await _lock.deviceHasBiometrics()) {
      final ok = await _lock.tryBiometric();
      if (!ok) {
        _snack("Fingerprint wasn't confirmed — the lock stays off.");
        return;
      }
    }
    await _lock.enable(pin);
    HapticFeedback.mediumImpact();
    _snack('App lock is on.');
  }

  Future<void> _turnOff() async {
    // Only the owner switches it off: fingerprint, else the PIN.
    var ok = await _lock.tryBiometric();
    if (!ok) {
      final pin = await _askPin(title: 'Enter your app PIN');
      if (pin == null) return;
      ok = await _lock.tryPin(pin);
    }
    if (!ok) {
      _snack('That PIN is not right.');
      return;
    }
    await _lock.disable();
    _snack('App lock is off.');
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const GroupLabel('Privacy & security'),
        GroupedCard(
          dividerInset: 60,
          children: [
            AppleRow(
              leading: IconTile(Icons.fingerprint_rounded, AppleColors.green),
              title: 'App lock',
              subtitle: 'Fingerprint or PIN to open the app',
              trailing: Switch(
                value: _lock.enabled,
                activeThumbColor: Colors.white,
                activeTrackColor: AppleColors.green,
                onChanged: (v) {
                  HapticFeedback.selectionClick();
                  v ? _turnOn() : _turnOff();
                },
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(left: 16, top: 6, right: 16),
          child: Text(
            'Locks when you have been away for more than a minute. Your PIN '
            'stays on this phone.',
            style: TextStyle(color: Neon.textDim, fontSize: 11.5),
          ),
        ),
      ],
    );
  }
}

class _PinDialog extends StatefulWidget {
  final String title;
  const _PinDialog({required this.title});

  @override
  State<_PinDialog> createState() => _PinDialogState();
}

class _PinDialogState extends State<_PinDialog> {
  final _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _c,
        autofocus: true,
        obscureText: true,
        maxLength: 4,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 24, letterSpacing: 12),
        onChanged: (v) {
          if (v.length == 4) Navigator.pop(context, v);
        },
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      ],
    );
  }
}
