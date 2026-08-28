import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:flutter/services.dart';

import '../../design/neon_tokens.dart';
import '../../services/auth_service.dart';
import 'state/assistant_engine.dart';
import 'state/assistant_state.dart';
import 'widgets/assistant_persona.dart';
import 'widgets/assistant_face.dart';
import '../../screens/diagnostics_screen.dart';
import '../../screens/clients_screen.dart';
import '../../screens/stocks_screen.dart';

class AssistantScreen extends StatefulWidget {
  const AssistantScreen({super.key});

  @override
  State<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends State<AssistantScreen> {
  final engine = AssistantEngine.instance;
  AssistantPersona _persona = AssistantPersona.neutral;
  bool _stocksEnabled = false;

  @override
  void initState() {
    super.initState();
    engine.start();
    engine.addListener(_onStateChanged);
    
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final persona = await AssistantPersonaResolver.resolve();
      if (!mounted) return;
      setState(() => _persona = persona);
      engine.greetingName = AuthService.instance.user?.name;
      engine.greetOnce(name: AuthService.instance.user?.name);
    });
  }

  void _onStateChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    engine.removeListener(_onStateChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height;
    return Scaffold(
      backgroundColor: const Color(0xFF06080E),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // LIVE AVATAR — rendered at SCREEN size, not through the portrait's
          // oversized hero circle.
          //
          // Simli publishes 360x360. The portrait layout below draws into a
          // box of h * 1.5 (~3510 px on this device) and crops back to the
          // screen, so only about a tenth of that width is visible — the
          // source ends up stretched roughly 10x and looks soft. Filling the
          // screen directly cuts the stretch to the minimum a 360 px square
          // needs to cover the display, which is the sharpest this source
          // can be without letterboxing it.
          if (engine.avatarTrack != null)
            Positioned.fill(
              child: lk.VideoTrackRenderer(
                engine.avatarTrack!,
                fit: lk.VideoViewFit.cover,
              ),
            )
          else
            // FULL SCREEN PORTRAIT (Massive circle that bleeds off the edges)
            Positioned(
              top: -h * 0.1,
              bottom: -h * 0.1,
              left: -h * 0.4,
              right: -h * 0.4,
              child: Center(
                child: AssistantFace(
                  size: h * 1.5,
                  phase: engine.phase,
                  persona: _persona,
                  speakingLevel: engine.micLevel,
                ),
              ),
            ),

          // TOP BAR
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                  child: Row(
                    children: [
                      IconButton(
                        icon: Icon(
                          _stocksEnabled ? Icons.candlestick_chart : Icons.candlestick_chart_outlined,
                          color: _stocksEnabled ? Neon.cyan : Colors.white54,
                        ),
                        onPressed: () => setState(() => _stocksEnabled = !_stocksEnabled),
                        tooltip: 'Toggle Market & Stocks',
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _persona.displayName,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.2,
                        ),
                      ),
                      const Spacer(),
                      _livePill(),
                    ],
                  ),
                ),
                
                if (!engine.connected || engine.errorMessage != null)
                  _connectionBanner(),

                const Spacer(),
                
                // BOTTOM BAR
                Container(
                  padding: const EdgeInsets.fromLTRB(24, 40, 24, 30),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.85),
                      ],
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                       _roundButton(
                        icon: Icons.folder_shared_rounded,
                        label: 'Clients',
                        onTap: () {
                           Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ClientsScreen()));
                        },
                      ),
                      if (_stocksEnabled)
                        _roundButton(
                          icon: Icons.trending_up_rounded,
                          label: 'Stocks',
                          onTap: () {
                             Navigator.of(context).push(MaterialPageRoute(builder: (_) => const StocksScreen()));
                          },
                        ),
                      _micButton(),
                       _roundButton(
                        icon: Icons.monitor_heart_outlined,
                        label: 'Diagnostics',
                        onTap: () {
                           Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DiagnosticsScreen()));
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _livePill() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8, height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: engine.connected ? const Color(0xFFE5484D) : Colors.grey,
              ),
            ),
            const SizedBox(width: 7),
            Text(engine.connected ? 'LIVE' : 'OFFLINE',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.4,
                )),
          ],
        ),
      );

  Widget _connectionBanner() => Padding(
        padding: const EdgeInsets.only(top: 16),
        child: GestureDetector(
          onTap: () {
            engine.dismissError();
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              color: Neon.warning.withValues(alpha: 0.15),
              border: Border.all(color: Neon.warning.withValues(alpha: 0.45)),
            ),
            child: Text(
              engine.errorMessage ?? 'Connecting...',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: Neon.warning.withValues(alpha: 0.95)),
            ),
          ),
        ),
      );

  Widget _micButton() {
    final isListening = engine.phase == AssistantPhase.listening;
    final isBusy = engine.phase.busy && !isListening;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: () {
            HapticFeedback.mediumImpact();
            engine.pressMic();
          },
          child: Transform.scale(
            scale: isListening ? 1.0 + (engine.micLevel * 0.4) : 1.0,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 100),
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isListening ? Colors.white : (isBusy ? Colors.grey.withValues(alpha: 0.3) : Neon.violet),
                border: isListening ? null : Border.all(color: Colors.white.withValues(alpha: 0.2), width: 2),
                boxShadow: isListening ? [
                  BoxShadow(color: Colors.white.withValues(alpha: 0.5 + (engine.micLevel * 0.5)), blurRadius: 20 + (engine.micLevel * 20), spreadRadius: 5 + (engine.micLevel * 10))
                ] : [],
              ),
              child: Icon(
                isBusy ? Icons.more_horiz_rounded : Icons.mic_rounded,
                color: isListening ? Neon.violet : Colors.white,
                size: 32,
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(isListening ? 'Listening...' : (isBusy ? 'Thinking...' : 'Tap to speak'),
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.75), fontSize: 12.5)),
      ],
    );
  }

  Widget _roundButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withValues(alpha: 0.14),
              border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
            ),
            child: Icon(icon, color: Colors.white, size: 24),
          ),
        ),
        const SizedBox(height: 6),
        Text(label,
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.75), fontSize: 11.5)),
      ],
    );
  }
}
