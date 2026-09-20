import 'package:flutter/material.dart';

import '../design/neon_tokens.dart';
import '../features/assistant/state/assistant_engine.dart';
import '../screens/calls_screen.dart';

/// A SMALL GREEN LIGHT WHILE THE ASSISTANT IS ON A CALL.
///
/// His ask, 2026-09-20: "don't display that current call on the orb
/// itself… add a small green kind of LED on the home page just to make
/// sure the agent is talking with you."
///
/// The call used to take over the card above the dock, which covered the
/// screen the user was on for the whole conversation. A call the
/// assistant makes is background work — it wants a status light, not the
/// foreground. Tapping it opens the Calls screen, where the reply lands.
///
/// Renders nothing at all when no call is running, so Home is unchanged
/// the rest of the time.
class CallLed extends StatefulWidget {
  const CallLed({super.key});

  @override
  State<CallLed> createState() => _CallLedState();
}

class _CallLedState extends State<CallLed> with SingleTickerProviderStateMixin {
  final _engine = AssistantEngine.instance;
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void initState() {
    super.initState();
    _engine.addListener(_onChange);
  }

  @override
  void dispose() {
    _engine.removeListener(_onChange);
    _pulse.dispose();
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final call = _engine.callStatus;
    if (call == null) return const SizedBox.shrink();

    const green = Color(0xFF35C48D);
    final who = call.contactName.trim().split(RegExp(r'\s+')).first;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const CallsScreen()),
          ),
          child: Container(
            padding: const EdgeInsets.fromLTRB(11, 7, 13, 7),
            decoration: BoxDecoration(
              color: green.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: green.withValues(alpha: 0.32)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // The light itself: a steady dot with a breathing halo, so
                // it reads as "live" from the corner of the eye without
                // animating anything the user has to look at.
                AnimatedBuilder(
                  animation: _pulse,
                  builder: (_, __) => Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      color: green,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: green.withValues(alpha: 0.55 * (1 - _pulse.value)),
                          blurRadius: 3 + 7 * _pulse.value,
                          spreadRadius: 1 + 3 * _pulse.value,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 9),
                Flexible(
                  child: Text(
                    who.isEmpty
                        ? 'On a call for you'
                        : '${_verb(call.status)} $who',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Neon.textHi,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Icon(Icons.chevron_right_rounded, size: 16, color: Neon.textDim),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _verb(String status) {
    switch (status) {
      case 'dialing':
        return 'Calling';
      case 'summarizing':
        return 'Wrapping up with';
      default:
        return 'Talking to';
    }
  }
}
