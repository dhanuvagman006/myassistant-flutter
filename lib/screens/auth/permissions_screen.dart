import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../design/apple_kit.dart';
import '../../design/neon_tokens.dart';
import '../../services/contacts_sync_service.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  PERMISSIONS GATE — a hard stop in onboarding.
///
///  The assistant is useless without its senses: no mic means no voice, no
///  contacts means "call Alan" dials nobody while the AI thinks it worked.
///  Rather than let each feature fail quietly the first time it's used,
///  every permission is collected up front and the app does not continue
///  until all of them are granted. The gate also re-appears on any later
///  launch where a permission has been revoked.
/// ─────────────────────────────────────────────────────────────────────────

class _PermItem {
  const _PermItem(this.p, this.icon, this.color, this.title, this.why);
  final Permission p;
  final IconData icon;
  final Color color;
  final String title;
  final String why;
}

const List<_PermItem> _kRequired = [
  _PermItem(Permission.microphone, Icons.mic_rounded, AppleColors.orange,
      'Microphone', 'Talking is how this app works.'),
  _PermItem(Permission.contacts, Icons.contacts_rounded, AppleColors.blue,
      'Contacts', 'So "call Alan" reaches the right Alan.'),
  _PermItem(Permission.phone, Icons.call_rounded, AppleColors.green, 'Phone',
      'To place the calls you ask for.'),
  _PermItem(Permission.notification, Icons.notifications_rounded,
      AppleColors.red, 'Notifications',
      'Reminders and messages arrive on time.'),
  _PermItem(Permission.camera, Icons.photo_camera_rounded, AppleColors.indigo,
      'Camera', 'Scan documents, receipts and reports.'),
  _PermItem(Permission.locationWhenInUse, Icons.place_rounded,
      AppleColors.teal, 'Location', 'Weather and places near you.'),
];

/// Launch-time check used by the setup gate: true only when every required
/// permission is already granted. Never prompts.
Future<bool> allRequiredPermissionsGranted() async {
  try {
    for (final item in _kRequired) {
      if (!await item.p.status.isGranted) return false;
    }
    return true;
  } catch (_) {
    // If the platform check itself fails, show the gate — it re-verifies.
    return false;
  }
}

class PermissionsScreen extends StatefulWidget {
  const PermissionsScreen({super.key, required this.onDone});

  final VoidCallback onDone;

  @override
  State<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends State<PermissionsScreen>
    with WidgetsBindingObserver {
  final Map<Permission, PermissionStatus> _status = {};
  bool _busy = false;
  bool _blocked = false; // something is permanently denied → Settings
  String? _error;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Coming back from the system Settings screen lands here — re-check so
  /// permissions granted there are picked up without any extra tap.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  bool get _allGranted =>
      _kRequired.isNotEmpty &&
      _kRequired.every((i) => _status[i.p]?.isGranted == true);

  Future<void> _refresh() async {
    for (final item in _kRequired) {
      try {
        _status[item.p] = await item.p.status;
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {});
    if (_allGranted) _finish();
  }

  void _finish() {
    if (_finished) return;
    _finished = true;
    // Contacts just became readable — sync names to the server now, so the
    // very first "call Alan" can already resolve.
    ContactsSyncService.instance.maybeSync(force: true);
    widget.onDone();
  }

  Future<void> _requestAll() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _blocked = false;
    });
    var anyPermanent = false;
    for (final item in _kRequired) {
      if (_status[item.p]?.isGranted == true) continue;
      try {
        final s = await item.p.request();
        _status[item.p] = s;
        if (s.isPermanentlyDenied) anyPermanent = true;
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (!_allGranted) {
        _blocked = anyPermanent;
        _error = anyPermanent
            ? 'Some permissions are blocked by Android. Open Settings, '
                'allow everything under Permissions, then come back.'
            : 'All permissions are required to continue. Please allow '
                'each one.';
      }
    });
    if (_allGranted) _finish();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Neon.bg,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 40, 24, 28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      width: 54,
                      height: 54,
                      decoration: BoxDecoration(
                        color: Neon.textHi,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Icon(Icons.verified_user_rounded,
                          color: Neon.onInk, size: 26),
                    ),
                  ),
                  const SizedBox(height: 22),
                  Text(
                    'Give it its senses',
                    style: GoogleFonts.spaceGrotesk(
                      fontSize: 26,
                      fontWeight: FontWeight.w700,
                      color: Neon.textHi,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Your assistant listens, calls, and scans for you. It '
                    'needs all of these to work — without them, features '
                    'would silently fail.',
                    style: TextStyle(
                        color: Neon.textLo, fontSize: 14.5, height: 1.45),
                  ),
                  const SizedBox(height: 22),
                  const GroupLabel('Required permissions'),
                  GroupedCard(
                    dividerInset: 60,
                    children: [
                      for (final item in _kRequired) _row(item),
                    ],
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Neon.error.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(_error!,
                          style: TextStyle(
                              color: Neon.error,
                              fontSize: 13,
                              height: 1.4)),
                    ),
                  ],
                  const SizedBox(height: 18),
                  _busy
                      ? FilledButton(
                          onPressed: null,
                          style: FilledButton.styleFrom(
                            backgroundColor: Neon.violet,
                            foregroundColor: Colors.white,
                            minimumSize: const Size.fromHeight(50),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                          ),
                          child: const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2.2, color: Colors.white),
                          ),
                        )
                      : ApplePrimaryButton(
                          label: _blocked ? 'Open Settings' : 'Allow all',
                          onPressed:
                              _blocked ? openAppSettings : _requestAll,
                        ),
                  const SizedBox(height: 10),
                  Text(
                    'Contacts stay on your phone — only names and numbers '
                    'sync, never photos or emails.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Neon.textDim, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(_PermItem item) {
    final granted = _status[item.p]?.isGranted == true;
    return AppleRow(
      leading: IconTile(item.icon, item.color),
      title: item.title,
      subtitle: item.why,
      trailing: granted
          ? Icon(Icons.check_circle_rounded, color: Neon.success, size: 22)
          : Text('Allow',
              style: TextStyle(
                  color: Neon.violet,
                  fontSize: 14,
                  fontWeight: FontWeight.w600)),
      onTap: granted || _busy
          ? null
          : () async {
              try {
                final s = await item.p.request();
                _status[item.p] = s;
                if (s.isPermanentlyDenied && mounted) {
                  setState(() {
                    _blocked = true;
                    _error =
                        '${item.title} is blocked by Android. Open Settings '
                        'and allow it there.';
                  });
                }
              } catch (_) {}
              if (mounted) setState(() {});
              if (_allGranted) _finish();
            },
    );
  }
}
