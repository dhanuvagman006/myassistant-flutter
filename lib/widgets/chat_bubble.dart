import 'package:flutter/material.dart';

import '../design/motion.dart';
import '../design/neon_tokens.dart';
import '../design/neon_widgets.dart' show NeonLoader;

/// ─────────────────────────────────────────────────────────────────────────
///  CHAT'S OWN PIECES (2026-09-30, the client's neon reference). The
///  one-to-one thread and the group drew their bubbles, composers and
///  badges twice, each a little differently (a filled violet bubble here,
///  a 22 % tint there). One set now, lit by hierarchy:
///   * what YOU sent is the brand gradient with a soft halo — the one lit
///     thing in a row of messages;
///   * what arrived is a dark elevated surface with a thin rim;
///   * the composer's rim lights up while you type into it, and its send
///     button is the screen's primary action — it glows.
/// ─────────────────────────────────────────────────────────────────────────

/// The sent bubble's two stops: the accent and its partner, each deep
/// enough that [ChatBubble.ink] reads on it at 4.5:1 (the accentFill rule,
/// applied to both ends of the gradient — the default Electric blue took
/// white words at only 3.3:1).
List<Color> chatSentStops() {
  final ink = Neon.onAccent;
  final key = Object.hash(Neon.violet.toARGB32(), Neon.pink.toARGB32(), ink.toARGB32());
  if (key != _stopsKey) {
    _stopsKey = key;
    _stops = [Neon.accentFill, _readable(Neon.pink, ink)];
  }
  return _stops!;
}

int? _stopsKey;
List<Color>? _stops;

double _contrast(Color a, Color b) {
  final x = a.computeLuminance(), y = b.computeLuminance();
  return (x > y ? x + 0.05 : y + 0.05) / (x > y ? y + 0.05 : x + 0.05);
}

/// [c] stepped darker (white words) or lighter (dark words) until [ink]
/// reads on it.
Color _readable(Color c, Color ink) {
  final darker = ink.computeLuminance() > 0.5;
  var h = HSLColor.fromColor(c);
  var out = c;
  var guard = 0;
  while (_contrast(out, ink) < 4.5 && guard++ < 100) {
    h = h.withLightness((h.lightness + (darker ? -0.01 : 0.01)).clamp(0.0, 1.0));
    out = h.toColor();
  }
  return out;
}

/// One message. [mine]: the brand gradient with its halo, tail bottom
/// right; otherwise the elevated surface with a rim, tail bottom left.
/// A long press ([onLongPress]) dips it under the finger.
class ChatBubble extends StatelessWidget {
  const ChatBubble({
    super.key,
    required this.mine,
    required this.child,
    this.onLongPress,
    this.maxWidthFactor = 0.78,
  });

  final bool mine;
  final Widget child;
  final VoidCallback? onLongPress;

  /// The widest it may be, as a share of the screen.
  final double maxWidthFactor;

  /// Words on a bubble.
  static Color ink(bool mine) => mine ? Neon.onAccent : Neon.textHi;

  /// Quieter words on a bubble (a label, a deleted note).
  static Color quietInk(bool mine) =>
      mine ? Neon.onAccent.withValues(alpha: 0.75) : Neon.textLo;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.only(
      topLeft: const Radius.circular(18),
      topRight: const Radius.circular(18),
      bottomLeft: Radius.circular(mine ? 18 : 5),
      bottomRight: Radius.circular(mine ? 5 : 18),
    );
    final bubble = Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
      constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * maxWidthFactor),
      decoration: mine
          ? BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: chatSentStops(),
              ),
              borderRadius: radius,
              boxShadow: Neon.halo(Neon.violet, strength: 0.3),
            )
          : BoxDecoration(
              color: Color.alphaBlend(
                  Neon.violet.withValues(alpha: 0.06), Neon.surface),
              borderRadius: radius,
              border: Border.all(color: Neon.lineBright, width: 1),
            ),
      child: child,
    );
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Tappable(
        onLongPress: onLongPress,
        scale: 0.98,
        tapHint: null,
        // The menu gives its own tick.
        haptic: false,
        child: bubble,
      ),
    );
  }
}

/// The unread count on a chat row: a small lit pill (an important state,
/// so it glows).
class ChatUnreadBadge extends StatelessWidget {
  const ChatUnreadBadge(this.count, {super.key});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$count unread',
      excludeSemantics: true,
      child: Container(
        constraints: const BoxConstraints(minWidth: 22),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: chatSentStops()),
          borderRadius: BorderRadius.circular(Neon.rPill),
          boxShadow: Neon.halo(Neon.violet, strength: 0.5),
        ),
        child: Text('$count',
            textAlign: TextAlign.center,
            style: NeonType.manrope(NeonType.caption, FontWeight.w700)
                .copyWith(color: Neon.onAccent)),
      ),
    );
  }
}

/// A person's round (their initial) or a group's (its [icon]) — on the
/// raised surface, with a thin brand rim. [selected] (picked for a new
/// group): the brand gradient with a tick, and its light.
class ChatAvatar extends StatelessWidget {
  const ChatAvatar({
    super.key,
    this.name = '',
    this.icon,
    this.selected = false,
    this.radius = 23,
  });

  final String name;
  final IconData? icon;
  final bool selected;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final d = radius * 2;
    final initial =
        name.isNotEmpty ? name.characters.first.toUpperCase() : '?';
    return ExcludeSemantics(
      child: AnimatedContainer(
        duration: Motion.reduced(context) ? Duration.zero : Motion.short,
        curve: Motion.easeMove,
        width: d,
        height: d,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: selected
                ? chatSentStops()
                : [Neon.surfaceHigh, Neon.surfaceHigh],
          ),
          border: Border.all(
              color: selected
                  ? Neon.violet
                  : Neon.violet.withValues(alpha: 0.35),
              width: 1.2),
          boxShadow: Neon.halo(Neon.violet, strength: selected ? 0.6 : 0),
        ),
        child: selected
            ? Icon(Icons.check_rounded, color: Neon.onAccent, size: radius)
            : icon != null
                ? Icon(icon, color: Neon.violet, size: radius)
                : Text(initial,
                    style: NeonType.manrope(NeonType.headline, FontWeight.w700)
                        .copyWith(color: Neon.textHi)),
      ),
    );
  }
}

/// The box you type a message into and its send button. The rim lights
/// (the brand's two colours, with a soft halo) while the box has the
/// keyboard; the send button is the brand gradient and glows — strongest
/// when there is something to send. [sending]: the button waits, turning.
class ChatComposer extends StatefulWidget {
  const ChatComposer({
    super.key,
    required this.controller,
    required this.onSend,
    this.hintText = 'Message…',
    this.sending = false,
    this.sendIcon = Icons.send_rounded,
    this.textCapitalization = TextCapitalization.sentences,
  });

  final TextEditingController controller;
  final VoidCallback onSend;
  final String hintText;
  final bool sending;
  final IconData sendIcon;
  final TextCapitalization textCapitalization;

  @override
  State<ChatComposer> createState() => _ChatComposerState();
}

class _ChatComposerState extends State<ChatComposer> {
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _ready = widget.controller.text.trim().isNotEmpty;
    _focus.addListener(_changed);
    widget.controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(ChatComposer old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _focus.dispose();
    super.dispose();
  }

  bool _lit = false, _ready = false;

  void _changed() {
    final lit = _focus.hasFocus;
    final ready = widget.controller.text.trim().isNotEmpty;
    if (lit != _lit || ready != _ready) {
      setState(() {
        _lit = lit;
        _ready = ready;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final still = Motion.reduced(context);
    final rim = _lit ? Neon.rim : [Neon.lineBright, Neon.lineBright];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: AnimatedContainer(
            duration: still ? Duration.zero : Motion.short,
            curve: Motion.easeMove,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: rim,
              ),
              boxShadow: Neon.halo(Neon.violet, strength: _lit ? 0.55 : 0),
            ),
            padding: const EdgeInsets.all(1.4),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Color.alphaBlend(
                    Neon.violet.withValues(alpha: 0.06), Neon.surface),
                borderRadius: BorderRadius.circular(22.6),
              ),
              child: TextField(
                controller: widget.controller,
                focusNode: _focus,
                minLines: 1,
                maxLines: 4,
                // Single-line to the keyboard, so its Send key sends (a
                // multi-line field makes Android type a newline instead).
                keyboardType: TextInputType.text,
                textInputAction: TextInputAction.send,
                textCapitalization: widget.textCapitalization,
                onSubmitted: (_) => widget.onSend(),
                onEditingComplete: () {},
                style: NeonType.manrope(NeonType.callout, FontWeight.w500)
                    .copyWith(color: Neon.textHi),
                cursorColor: Neon.cyan,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: widget.hintText,
                  hintStyle: TextStyle(color: Neon.textLo),
                  filled: false,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        _SendButton(
          icon: widget.sendIcon,
          busy: widget.sending,
          ready: _ready,
          onPressed: widget.onSend,
        ),
      ],
    );
  }
}

class _SendButton extends StatelessWidget {
  const _SendButton({
    required this.icon,
    required this.busy,
    required this.ready,
    required this.onPressed,
  });

  final IconData icon;
  final bool busy, ready;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final button = AnimatedContainer(
      duration: Motion.reduced(context) ? Duration.zero : Motion.short,
      curve: Motion.easeMove,
      width: 50,
      height: 50,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: chatSentStops(),
        ),
        // The primary action glows; brightest with words waiting to go.
        boxShadow:
            Neon.halo(Neon.violet, strength: busy ? 0.3 : ready ? 1 : 0.55),
      ),
      child: busy
          ? const NeonLoader.inline(semanticLabel: 'Sending')
          : Icon(icon, color: Neon.onAccent, size: 22),
    );
    // Busy, it is the turning ring, which says "Sending" itself.
    return Tappable(
      onTap: busy ? null : onPressed,
      scale: 0.92,
      semanticLabel: 'Send',
      tapHint: 'send',
      child: button,
    );
  }
}
