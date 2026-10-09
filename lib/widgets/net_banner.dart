import 'dart:async';

import 'package:flutter/material.dart';

import '../design/neon_tokens.dart';
import '../services/net_status.dart';

/// The app's one word on the connection, over every screen: "No internet
/// connection" or "Can't reach MyAssistant right now", and a short "Back
/// online" when it returns. Tap to look again. Nothing while all is well.
class NetBanner extends StatefulWidget {
  const NetBanner({super.key, required this.child});
  final Widget child;

  @override
  State<NetBanner> createState() => _NetBannerState();
}

class _NetBannerState extends State<NetBanner> with WidgetsBindingObserver {
  final _net = NetStatus.instance;
  NetState _shown = NetState.ok;
  bool _back = false;
  Timer? _backTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _net.state.addListener(_changed);
    unawaited(_net.check());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) unawaited(_net.check());
  }

  void _changed() {
    final next = _net.state.value;
    if (!mounted || next == _shown) return;
    setState(() {
      _back = next == NetState.ok && _shown != NetState.ok;
      _shown = next;
    });
    _backTimer?.cancel();
    if (_back) {
      _backTimer = Timer(const Duration(seconds: 2), () {
        if (mounted) setState(() => _back = false);
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _net.state.removeListener(_changed);
    _backTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final visible = _shown != NetState.ok || _back;
    final (icon, text, color) = switch (_shown) {
      NetState.offline => (
          Icons.wifi_off_rounded,
          'No internet connection. Check Wi-Fi or mobile data.',
          const Color(0xFFE5484D),
        ),
      NetState.serverDown => (
          Icons.cloud_off_rounded,
          "Can't reach MyAssistant right now. Trying again…",
          const Color(0xFFD9822B),
        ),
      NetState.ok => (Icons.wifi_rounded, 'Back online', const Color(0xFF2E9E6A)),
    };
    return Stack(
      children: [
        widget.child,
        Positioned(
          left: 12,
          right: 12,
          top: 0,
          child: SafeArea(
            bottom: false,
            child: IgnorePointer(
              ignoring: !visible,
              child: AnimatedSlide(
                offset: visible ? Offset.zero : const Offset(0, -1.6),
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                child: AnimatedOpacity(
                  opacity: visible ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Semantics(
                    liveRegion: true,
                    label: text,
                    button: _shown != NetState.ok,
                    child: Material(
                      color: color,
                      elevation: 6,
                      shadowColor: Colors.black45,
                      borderRadius: BorderRadius.circular(Neon.rPill),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(Neon.rPill),
                        onTap: _shown == NetState.ok ? null : () => unawaited(_net.check()),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(icon, color: Colors.white, size: 18),
                              const SizedBox(width: 10),
                              Flexible(
                                child: Text(
                                  text,
                                  maxLines: 2,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w600,
                                    height: 1.25,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
