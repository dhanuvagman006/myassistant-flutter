import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/log.dart';
import '../../design/motion.dart';
import '../../design/neon_tokens.dart';
import '../../design/neon_widgets.dart';
import '../../services/app_feedback.dart';
import '../../services/avatar_message_service.dart';

/// One address on screen: whose, which one, where.
@immutable
class AddressCard {
  const AddressCard({
    required this.name,
    required this.label,
    required this.address,
    this.phone,
    this.saved = false,
  });

  final String name;
  final String label;
  final String address;

  /// The person's number when it is on file: the sheet offers a call.
  final String? phone;

  /// Just saved by remember_address (vs. looked up by show_address).
  final bool saved;

  /// "Ravi Kumar" → "Ravi" (the Call button's words).
  String get firstName {
    final parts = name.trim().split(RegExp(r'\s+'));
    return parts.first.isEmpty ? name : parts.first;
  }

  /// "home" → "Home"; empty → "Home" (the server's default label).
  String get labelTitle {
    final l = label.trim();
    if (l.isEmpty) return 'Home';
    return l[0].toUpperCase() + l.substring(1);
  }
}

/// ─────────────────────────────────────────────────────────────────────────
///  THE ADDRESS SHEET (2026-09-30, owner: "remember Ravi's house address"
///  and later "what's Ravi's address" — "it should show us"). The server's
///  remember_address / show_address tools send a `show_address` directive;
///  this sheet pops over whatever is on screen with the address large and
///  selectable, and Maps / Share / Copy / Call one tap away. The voice turn
///  keeps going underneath.
/// ─────────────────────────────────────────────────────────────────────────
class AddressSheet {
  AddressSheet._();

  /// Opens a URL outside the app (Maps, the dialer). Tests swap it.
  @visibleForTesting
  static Future<bool> Function(Uri uri) launch =
      (uri) => launchUrl(uri, mode: LaunchMode.externalApplication);

  /// Hands text to the system share sheet. Tests swap it.
  @visibleForTesting
  static Future<void> Function(String text) share =
      (text) async => Share.share(text);

  /// What is on screen; a second directive while the sheet is up replaces
  /// it in place rather than stacking a second sheet.
  static final ValueNotifier<AddressCard?> _current = ValueNotifier(null);

  /// The open sheet's context: gone (unmounted) once it closes, or when
  /// the app's navigator is rebuilt under it.
  static BuildContext? _sheet;
  static int _shown = 0;

  static bool get isOpen => _sheet?.mounted ?? false;

  /// Google Maps' search for [address] (opens the Maps app when installed).
  static Uri mapsUri(String address) => Uri.parse(
      'https://www.google.com/maps/search/?api=1&query=${Uri.encodeComponent(address.trim())}');

  /// The dialer with [phone] (spaces and dashes dropped).
  static Uri telUri(String phone) =>
      Uri(scheme: 'tel', path: phone.replaceAll(RegExp(r'[^\d+]'), ''));

  /// The engine's entry: a `show_address` device action.
  static Future<void> fromDirective(Map<String, dynamic> e) {
    final phone = (e['phone'] ?? '').toString().trim();
    return show(
      name: (e['name'] ?? '').toString().trim(),
      label: (e['label'] ?? 'home').toString().trim(),
      address: (e['address'] ?? '').toString().trim(),
      phone: phone.isEmpty ? null : phone,
      saved: e['saved'] == true,
    );
  }

  /// Shows the address over whatever is on screen (the root navigator).
  static Future<void> show({
    required String name,
    required String label,
    required String address,
    String? phone,
    bool saved = false,
  }) async {
    if (address.trim().isEmpty) {
      AppLog.add('address', 'show_address with no address for "$name"');
      return;
    }
    final card = AddressCard(
        name: name.isEmpty ? 'Address' : name,
        label: label,
        address: address.trim(),
        phone: phone,
        saved: saved);
    _current.value = card;
    if (isOpen) return; // the open sheet shows the new one
    final ctx = AvatarMessageService.navigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) {
      AppLog.add('address', 'no screen to show the address on');
      return;
    }
    final mine = ++_shown;
    HapticFeedback.lightImpact();
    try {
      await showAppSheet<void>(
        context: ctx,
        isScrollControlled: true,
        useRootNavigator: true,
        backgroundColor: Colors.transparent,
        builder: (sheet) {
          _sheet = sheet;
          return ValueListenableBuilder<AddressCard?>(
            valueListenable: _current,
            builder: (_, c, __) => AddressSheetView(card: c ?? card),
          );
        },
      );
    } finally {
      if (_shown == mine) _sheet = null;
    }
  }
}

/// The sheet itself.
class AddressSheetView extends StatefulWidget {
  const AddressSheetView({super.key, required this.card});
  final AddressCard card;

  @override
  State<AddressSheetView> createState() => _AddressSheetViewState();
}

class _AddressSheetViewState extends State<AddressSheetView> {
  bool _copied = false;
  Timer? _reset;

  @override
  void didUpdateWidget(AddressSheetView old) {
    super.didUpdateWidget(old);
    if (old.card.address != widget.card.address) _copied = false;
  }

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  AddressCard get _c => widget.card;

  Future<void> _maps() async {
    final ok = await _safeLaunch(AddressSheet.mapsUri(_c.address));
    if (!ok) AppFeedback.show("Couldn't open Maps", tone: FeedbackTone.error);
  }

  Future<void> _call() async {
    final ok = await _safeLaunch(AddressSheet.telUri(_c.phone!));
    if (!ok) AppFeedback.show("Couldn't start the call", tone: FeedbackTone.error);
  }

  Future<bool> _safeLaunch(Uri uri) async {
    try {
      return await AddressSheet.launch(uri);
    } catch (err) {
      AppLog.add('address', 'launch $uri failed: $err');
      return false;
    }
  }

  Future<void> _share() async {
    try {
      await AddressSheet.share('${_c.name} — ${_c.labelTitle} address:\n${_c.address}');
    } catch (err) {
      AppLog.add('address', 'share failed: $err');
    }
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _c.address));
    if (!mounted) return;
    // The toast waits for the sheet to close (app policy); the button says
    // it at once.
    setState(() => _copied = true);
    _reset?.cancel();
    _reset = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
    AppFeedback.show('Address copied', context: context, tone: FeedbackTone.success);
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Container(
      decoration: BoxDecoration(
        color: Neon.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(Neon.rXl)),
        border: Border(top: BorderSide(color: Neon.lineBright, width: 1.2)),
        boxShadow: Neon.halo(Neon.violet, strength: 0.6),
      ),
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(18, 10, 18, 18 + bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                    color: Neon.lineBright, borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: 14),
            _header(),
            const SizedBox(height: 10),
            Text(_c.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: NeonType.manrope(NeonType.title2, FontWeight.w800)
                    .copyWith(color: Neon.textHi, height: 1.15)),
            const SizedBox(height: 10),
            Align(alignment: Alignment.centerLeft, child: _labelChip()),
            const SizedBox(height: 16),
            _addressCard(),
            const SizedBox(height: 20),
            // Side by side when they fit; they wrap onto a second line with
            // large text rather than overflowing.
            Wrap(
              spacing: 10,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _MapsButton(onTap: _maps),
                NeonPill(
                  label: 'Share',
                  icon: Icons.ios_share_rounded,
                  tone: NeonTone.info,
                  onPressed: _share,
                ),
                NeonPill(
                  label: _copied ? 'Copied' : 'Copy',
                  icon: _copied ? Icons.check_rounded : Icons.copy_rounded,
                  tone: _copied ? NeonTone.success : NeonTone.tip,
                  onPressed: _copy,
                ),
                if (_c.phone != null)
                  NeonPill(
                    label: 'Call ${_c.firstName}',
                    icon: Icons.call_rounded,
                    tone: NeonTone.success,
                    onPressed: _call,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    final saved = _c.saved;
    final ink = saved ? NeonTone.success.ink : Neon.textLo;
    return Semantics(
      header: true,
      label: saved ? 'Saved' : 'Address',
      child: ExcludeSemantics(
        child: Row(
          children: [
            Icon(saved ? Icons.check_circle_rounded : Icons.place_outlined,
                size: 18, color: ink),
            const SizedBox(width: 6),
            Text(saved ? 'Saved' : 'Address',
                style: NeonType.manrope(NeonType.footnote, FontWeight.w700)
                    .copyWith(color: ink, letterSpacing: 0.3)),
          ],
        ),
      ),
    );
  }

  Widget _labelChip() {
    const tone = NeonTone.tip;
    return Semantics(
      label: '${_c.labelTitle} address',
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: tone.fill,
            borderRadius: BorderRadius.circular(Neon.rPill),
            border: Border.all(color: tone.rim.first.withValues(alpha: 0.7)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_labelIcon(_c.label), size: 16, color: tone.ink),
              const SizedBox(width: 6),
              Text(_c.labelTitle,
                  style: NeonType.manrope(NeonType.footnote, FontWeight.w700)
                      .copyWith(color: Neon.textHi)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _addressCard() {
    const tone = NeonTone.info;
    return GlowCard(
      tone: tone,
      halo: 0.8,
      radius: Neon.rXl,
      padding: const EdgeInsets.fromLTRB(16, 16, 18, 18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(Neon.rSm),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    for (final c in tone.rim) c.withValues(alpha: 0.28),
                  ],
                ),
                border: Border.all(color: tone.rim.first.withValues(alpha: 0.6)),
              ),
              child: Icon(Icons.location_on_rounded, color: tone.ink, size: 24),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: SelectableText(
              _c.address,
              style: NeonType.manrope(NeonType.title3 + 2, FontWeight.w600)
                  .copyWith(color: Neon.textHi, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }

  static IconData _labelIcon(String label) => switch (label.trim().toLowerCase()) {
        'home' || 'house' || '' => Icons.home_rounded,
        'office' || 'work' => Icons.work_rounded,
        'shop' || 'store' => Icons.storefront_rounded,
        _ => Icons.place_rounded,
      };
}

/// The primary action: a filled, strongly lit pill.
class _MapsButton extends StatelessWidget {
  const _MapsButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Deepened a fifth toward the night so the white words read (AA), as
    // the reminder pop-up's Done.
    final fill = [
      for (final c in [Neon.violet, Neon.pink]) Color.lerp(c, Neon.bg, 0.22)!,
    ];
    return Tappable(
      onTap: onTap,
      semanticLabel: 'Open in Maps',
      child: ExcludeSemantics(
        child: Container(
          height: 52,
          padding: const EdgeInsets.fromLTRB(16, 6, 20, 6),
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: fill),
            borderRadius: BorderRadius.circular(Neon.rPill),
            boxShadow: Neon.halo(fill.first, strength: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.map_rounded, color: Neon.textHi, size: 22),
              const SizedBox(width: 8),
              Text('Open in Maps',
                  style: NeonType.manrope(NeonType.rowTitle, FontWeight.w800).copyWith(
                    color: Neon.textHi,
                    shadows: [Shadow(color: Neon.bg.withValues(alpha: 0.45), blurRadius: 6)],
                  )),
            ],
          ),
        ),
      ),
    );
  }
}
