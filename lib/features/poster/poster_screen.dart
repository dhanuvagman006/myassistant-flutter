import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../design/apple_kit.dart';
import '../../design/neon_tokens.dart';
import '../../design/neon_widgets.dart';
import '../../services/app_feedback.dart';
import '../../services/avatar_message_service.dart';
import '../assistant/state/assistant_engine.dart';
import '../poster_studio/studio_actions.dart';
import 'photo_source_sheet.dart';
import 'poster_controller.dart';
import 'poster_fonts.dart';
import 'poster_layout.dart';
import 'poster_models.dart';
import 'poster_painter.dart';
import 'poster_palettes.dart';
import 'poster_share.dart';
import 'poster_templates.dart';
import 'signature/signature_pad.dart';
import '../../design/motion.dart';

/// Opens the card screen from anywhere (the Hub, a device action), never
/// stacking a second copy.
abstract final class PosterNav {
  static bool show({bool latest = false}) {
    if (PosterScreen.showing > 0) return true;
    final nav = AvatarMessageService.navigatorKey.currentState;
    if (nav == null) return false;
    unawaited(nav.push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => PosterScreen(openLatest: latest),
    )));
    return true;
  }

  /// A photo shared into the app, and he chose "Make a birthday card".
  static Future<void> cardFromPhoto(PickedPhoto photo) async {
    final c = PosterController.instance;
    await c.startNew();
    show();
    await c.addPhoto(photo);
  }
}

/// ─────────────────────────────────────────────────────────────────────────
///  PHOTO CARDS — the card, big, and every change as a big labelled button.
///
///  The client is an elderly father who mostly talks to the app (2026-09-26:
///  "make a birthday card for my daughter… with my signature"). So: the
///  card fills the top of the screen exactly as it will be sent; one green
///  button sends it on WhatsApp; each line of words opens its own large
///  editor; and the mic at the bottom lets him say "bigger", "pink" or "use
///  the other design" without finding anything. The controls follow the
///  phone's text size; the card itself never does (it is a picture).
/// ─────────────────────────────────────────────────────────────────────────
class PosterScreen extends StatefulWidget {
  const PosterScreen({
    super.key,
    this.controller,
    this.openLatest = false,
    this.voiceBar = true,
  });

  final PosterController? controller;

  /// From the Hub: show his latest card (or a fresh one).
  final bool openLatest;

  /// The mic along the bottom (off in widget tests).
  final bool voiceBar;

  static int showing = 0;

  @override
  State<PosterScreen> createState() => _PosterScreenState();
}

// 2026-09-30 visual QA: the hard-coded WhatsApp green (0xFF0E7A43) is gone;
// the page's one filled button takes the app's primary fill, as Poster
// Studio's "Share on WhatsApp" and every other primary action do.

class _PosterScreenState extends State<PosterScreen> {
  late final PosterController c = widget.controller ?? PosterController.instance;
  bool _showMove = false;

  @override
  void initState() {
    super.initState();
    PosterScreen.showing++;
    c.addListener(_changed);
    if (widget.openLatest) {
      unawaited(c.openLatestOrNew());
    } else if (c.poster == null && c.mode == 'poster') {
      unawaited(c.startNew());
    }
    unawaited(PosterFonts.ensureLoaded().then((_) => _changed()));
  }

  @override
  void dispose() {
    PosterScreen.showing--;
    c.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _toast(String text) {
    if (!mounted) return;
    AppFeedback.show(text, context: context);
  }

  // ── actions ────────────────────────────────────────────────────────────

  Future<void> _pickPhoto() async {
    PickedPhoto? picked;
    try {
      picked = await PhotoSourceSheet.pick(context, 'ask');
    } on PhotoAccessDenied {
      return; // the way to Settings is already on the screen
    }
    if (picked == null) return;
    final ok = await c.addPhoto(picked);
    if (!ok) _toast(c.notice ?? "That photo couldn't be opened. Please pick another one.");
  }

  Future<void> _send({String app = 'whatsapp'}) async {
    if (c.allNeeds.isNotEmpty) {
      _toast('Please shorten ${fieldLabel(c.allNeeds.first.field)} first.');
      return;
    }
    final out = await c.share(app: app);
    if (out == ShareOutcome.photoMissing) _toast(c.notice ?? 'Your photo is still on its way.');
    if (out == ShareOutcome.failed) _toast("The card couldn't be sent just now. Please try again.");
  }

  Future<void> _save() async {
    final out = await c.saveToPhotos();
    if (out == ShareOutcome.saved) _toast('Saved to your Photos.');
    if (out == ShareOutcome.photoMissing) _toast(c.notice ?? 'Your photo is still on its way.');
    if (out == ShareOutcome.failed) _toast("The card couldn't be saved just now.");
  }

  Future<void> _sign() async {
    final s = await SignaturePadScreen.open(context, store: c.signatures);
    if (s != null) c.useSignature(s);
  }

  Future<void> _edit(String field) async {
    final spec = c.spec;
    // The automatic heading is offered as a hint, not as his words: saving
    // it untouched must not freeze "Happy 25th Birthday" when she turns 26
    // (review, 2026-09-26).
    final auto = field == 'headline' && !spec.headlineCustom;
    final result = await showAppDialog<String>(
      context: context,
      builder: (_) => _LineEditor(
        field: field,
        initial: auto ? '' : _current(field),
        hint: field == 'headline' ? spec.printedHeadline : null,
      ),
    );
    if (result == null) return;
    if (field == 'age') {
      final n = int.tryParse(result.trim());
      final age = n != null && n > 0 && n <= 120 ? n : null;
      if (age != spec.age) c.apply(PosterChange(set: {'age': age}));
      return;
    }
    final cleaned = cleanLine(field, result);
    if (auto && (cleaned.isEmpty || cleaned == spec.printedHeadline)) return;
    if (!auto && cleaned == cleanLine(field, _current(field))) return;
    final ok = c.apply(PosterChange(set: {field: result}));
    if (!ok && c.needs.isNotEmpty) {
      final n = c.needs.first;
      _toast('Please make ${fieldLabel(n.field)} a little shorter'
          '${n.max != null ? ' (up to ${n.max} letters)' : ''}.');
    }
  }

  String _current(String field) => switch (field) {
        'headline' => c.spec.printedHeadline,
        'name' => c.spec.name,
        'age' => c.spec.age?.toString() ?? '',
        'message' => c.spec.message,
        'from' => c.spec.from,
        'date' => c.spec.date,
        _ => '',
      };

  void _tapCard(Offset local, Size shown) {
    final l = c.prepared.layout;
    final k = l.size.width / shown.width;
    final p = local * k;
    for (final b in l.blocks) {
      if (b.rect.inflate(12).contains(p)) {
        _edit(b.field == 'age' ? 'age' : b.field);
        return;
      }
    }
    if (l.frame != null && l.frame!.inflate(20).contains(p)) unawaited(_pickPhoto());
  }

  // ── build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final photoMode = c.mode == 'photo';
    // The night sky behind the card, like every pushed page (2026-09-30).
    return NeonScaffold(
      appBar: appleAppBar(context, photoMode ? 'Your photo' : 'Your card'),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(child: photoMode ? _photoMode() : _posterMode()),
            if (widget.voiceBar) const PosterVoiceBar(),
          ],
        ),
      ),
    );
  }

  Widget _posterMode() {
    final spec = c.spec;
    final prepared = c.poster == null ? null : c.prepared;
    final needs = c.poster == null ? const <PosterNeed>[] : c.allNeeds;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        if (prepared != null)
          LayoutBuilder(builder: (context, box) {
            final ratio = prepared.size.width / prepared.size.height;
            final maxH = MediaQuery.sizeOf(context).height * 0.56;
            final w = (maxH * ratio).clamp(0.0, box.maxWidth);
            return Center(
              child: SizedBox(
                width: w,
                height: w / ratio,
                child: GestureDetector(
                  onTapUp: (d) => _tapCard(d.localPosition, Size(w, w / ratio)),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      boxShadow: Neon.cardShadow,
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: PosterPreview(prepared: prepared),
                    ),
                  ),
                ),
              ),
            );
          })
        else
          const SizedBox(height: 320, child: NeonLoader.page(label: 'Opening your card…')),
        const SizedBox(height: 10),
        if (c.photoLoading || c.addingPhoto)
          const _Chip(icon: Icons.hourglass_top_rounded, text: 'Adding your photo…'),
        if (c.photoFailed && !c.photoLoading)
          _NeedCard(
            text: "Your photo didn't come through. Please check the internet and try again.",
            action: 'Try the photo again',
            icon: Icons.refresh_rounded,
            onFix: c.retryPhoto,
          ),
        if (c.notice != null) _Chip(icon: Icons.info_outline_rounded, text: c.notice!),
        if (c.offline)
          const _Chip(
              icon: Icons.cloud_off_rounded,
              text: 'Kept on this phone for now — it can still be sent.'),
        if (c.limitReached)
          const _Chip(icon: Icons.format_size_rounded, text: 'The words are as big as this card allows.'),
        for (final n in needs.take(1))
          _NeedCard(
            text: n.reason == 'no_room'
                ? '${_cap(fieldLabel(n.field))} ${n.field == 'message' ? 'are' : 'is'} a little long for this card. Please make ${n.field == 'message' ? 'them' : 'it'} shorter.'
                : 'Please make ${fieldLabel(n.field)} shorter${n.max != null ? ' (up to ${n.max} letters)' : ''}.',
            onFix: () => _edit(n.field),
          ),
        const SizedBox(height: 6),
        BigButton(
          icon: Icons.send_rounded,
          label: 'Send on WhatsApp',
          onPressed: c.busy || c.poster == null ? null : () => _send(),
        ),
        const SizedBox(height: 10),
        // 2026-09-30 visual QA: an even grid — the wrap left them ragged
        // (one long button alone, then two short ones hugging the left).
        BigButton(icon: Icons.download_rounded, label: 'Save to my photos', onPressed: c.busy ? null : _save, outlined: true),
        const SizedBox(height: 10),
        _pair(
          BigButton(icon: Icons.ios_share_rounded, label: 'Other apps', onPressed: c.busy ? null : () => _send(app: 'any'), outlined: true),
          // Undo sits with the big buttons, not as a small app-bar icon.
          BigButton(icon: Icons.undo_rounded, label: 'Undo', onPressed: c.canUndo ? c.undo : null, outlined: true),
        ),
        _section('The words'),
        for (final f in ['headline', 'name', if (spec.occasion == 'birthday' || spec.occasion == 'anniversary') 'age', 'message', 'from', 'date'])
          _LineTile(field: f, value: _current(f), onTap: () => _edit(f)),
        const SizedBox(height: 8),
        _pair(
          BigButton(icon: Icons.text_increase_rounded, label: 'Bigger words',
              onPressed: () => c.apply(const PosterChange(textSize: 'bigger')), outlined: true),
          BigButton(icon: Icons.text_decrease_rounded, label: 'Smaller words',
              onPressed: () => c.apply(const PosterChange(textSize: 'smaller')), outlined: true),
        ),
        _section('Design'),
        _DesignCarousel(controller: c),
        _section('Colour'),
        _wrap([
          for (final col in posterColours)
            _ColourChip(
              colour: col,
              palette: posterPalette(col, deep: posterTemplate(spec.design).deepFor(col)),
              selected: spec.colour == col,
              onTap: () => c.apply(PosterChange(colour: col)),
            ),
        ]),
        _section('Photo'),
        _wrap([
          BigButton(
            icon: Icons.add_photo_alternate_rounded,
            label: c.poster?.photo == null ? 'Choose a photo' : 'Change photo',
            onPressed: _pickPhoto,
            outlined: c.poster?.photo != null,
          ),
          if (c.poster?.photo != null)
            BigButton(
              icon: spec.photoUse == 'none' ? Icons.image_rounded : Icons.hide_image_rounded,
              label: spec.photoUse == 'none' ? 'Show the photo' : 'No photo',
              onPressed: () => c.apply(PosterChange(
                  photoUse: spec.photoUse == 'none'
                      ? (c.poster!.photo!.variants.contains('enhanced') ? 'enhanced' : 'original')
                      : 'none')),
              outlined: true,
            ),
          if (c.poster?.photo != null && spec.photoUse != 'none')
            BigButton(
              icon: Icons.open_with_rounded,
              label: _showMove ? 'Done moving' : 'Move photo',
              onPressed: () => setState(() => _showMove = !_showMove),
              outlined: true,
            ),
        ]),
        if (_showMove && c.poster?.photo != null) _MovePanel(controller: c),
        if (c.poster?.photo != null && spec.photoUse != 'none') ...[
          const SizedBox(height: 10),
          _wrap([
            for (final (value, label) in const [
              ('keep', 'As it is'),
              ('bw', 'Black & white'),
              ('sepia', 'Old brown'),
            ])
              _ChoiceChip(
                label: label,
                // The CARD's photo colour (contract v2): undo takes it back.
                selected: spec.photoColour == value,
                onTap: () => c.setPhotoColour(value),
              ),
          ]),
          if (c.poster!.photo!.variants.contains('enhanced')) ...[
            const SizedBox(height: 10),
            _wrap([
              _ChoiceChip(
                label: 'Cleaned-up photo',
                selected: spec.photoUse == 'enhanced',
                onTap: () => c.apply(const PosterChange(photoUse: 'enhanced')),
              ),
              _ChoiceChip(
                label: 'Photo as it was',
                selected: spec.photoUse == 'original',
                onTap: () => c.apply(const PosterChange(photoUse: 'original')),
              ),
            ]),
          ],
        ],
        _section('Signature'),
        _wrap([
          if (c.signature == null)
            BigButton(icon: Icons.draw_rounded, label: 'Sign the card', onPressed: _sign, outlined: true)
          else ...[
            _ChoiceChip(
              label: spec.signature ? 'Signature on the card' : 'Signature off',
              selected: spec.signature,
              onTap: () => c.apply(PosterChange(signature: !spec.signature)),
            ),
            BigButton(icon: Icons.draw_rounded, label: 'Sign again', onPressed: _sign, outlined: true),
            BigButton(
              icon: Icons.delete_outline_rounded,
              label: 'Delete my signature',
              onPressed: () async {
                await c.deleteSignature();
                _toast('Your signature was deleted from this phone.');
              },
              outlined: true,
            ),
          ],
        ]),
        _section('Size'),
        _wrap([
          _ChoiceChip(
            label: 'Card (for chats)',
            selected: spec.format == 'portrait',
            onTap: () => c.apply(const PosterChange(format: 'portrait')),
          ),
          _ChoiceChip(
            label: 'Tall (WhatsApp status)',
            selected: spec.format == 'story',
            onTap: () => c.apply(const PosterChange(format: 'story')),
          ),
        ]),
        const SizedBox(height: 22),
        BigButton(
          icon: Icons.add_rounded,
          label: 'Start a new card',
          onPressed: () => c.startNew(),
          outlined: true,
        ),
        const SizedBox(height: 16),
        // POSTER STUDIO (2026-09-30): an event poster (a party, a meeting,
        // a sale) is its own studio — words set by the phone over an AI
        // background. Reached from here until the Hub has its own row.
        GlowCard(
          tone: NeonTone.discovery,
          halo: 0.35,
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          semanticLabel: 'Poster Studio: make a poster for an event',
          onTap: () => PosterStudioNav.open(context),
          child: Row(
            children: [
              IconTile(Icons.campaign_rounded, Neon.violet, size: 40),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Poster Studio',
                        style: NeonType.manrope(NeonType.rowTitle, FontWeight.w800)
                            .copyWith(color: Neon.textHi)),
                    Text('A poster for an event — party, meeting, festival',
                        style: NeonType.manrope(NeonType.footnote, FontWeight.w500)
                            .copyWith(color: Neon.textLo)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: Neon.textLo),
            ],
          ),
        ),
      ],
    );
  }

  Widget _photoMode() {
    final ph = c.loosePhoto;
    Widget pane(String label, ui.Image? img) => Expanded(
          child: Column(
            children: [
              Text(label,
                  style: NeonType.manrope(NeonType.rowTitle, FontWeight.w700)
                      .copyWith(color: Neon.textHi)),
              const SizedBox(height: 6),
              AspectRatio(
                aspectRatio: ph?.aspect ?? 0.75,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: img == null
                      ? ColoredBox(
                          color: Neon.surface,
                          child: const Center(child: NeonLoader(size: 32)))
                      : RawImage(image: img, fit: BoxFit.cover),
                ),
              ),
            ],
          ),
        );
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            pane('Before', c.looseOriginal),
            const SizedBox(width: 10),
            pane('After', c.looseEnhanced ?? c.looseOriginal),
          ],
        ),
        const SizedBox(height: 12),
        if (c.notice != null) _Chip(icon: Icons.info_outline_rounded, text: c.notice!),
        if (ph != null && !ph.variants.contains('enhanced'))
          const _Chip(
              icon: Icons.info_outline_rounded,
              text: 'This photo is shown as it is — the clean-up is not available right now.'),
        if (ph != null && ph.variants.contains('enhanced')) ...[
          _wrap([
            for (final (value, label) in const [
              ('keep', 'As it is'),
              ('bw', 'Black & white'),
              ('sepia', 'Old brown'),
            ])
              _ChoiceChip(
                label: label,
                selected: ph.colour == value,
                onTap: () => c.recolourLoosePhoto(value),
              ),
          ]),
          const SizedBox(height: 12),
        ],
        const SizedBox(height: 6),
        BigButton(
          icon: Icons.cake_rounded,
          label: 'Make a birthday card with it',
          onPressed: ph == null ? null : () => c.cardFromLoosePhoto(),
        ),
        const SizedBox(height: 10),
        BigButton(
          icon: Icons.save_alt_rounded,
          label: 'Keep the clearer photo',
          onPressed: ph == null
              ? null
              : () async {
                  if (await c.keepLoosePhoto()) _toast('Saved in My documents.');
                },
          outlined: true,
        ),
      ],
    );
  }

  static String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 24, 4, 10),
        child: Text(title,
            style: NeonType.manrope(NeonType.title3, FontWeight.w700).copyWith(color: Neon.textHi)),
      );

  Widget _wrap(List<Widget> children) => Wrap(spacing: 10, runSpacing: 10, children: children);

  /// Two big buttons sharing a row, each half, the same height (a label
  /// that wraps at large text makes both taller together).
  Widget _pair(Widget a, Widget b) => IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [Expanded(child: a), const SizedBox(width: 10), Expanded(child: b)],
        ),
      );
}

// ───────────────────────────── the preview ──────────────────────────────

/// The card, drawn once into a picture and replayed at the size it is
/// shown — the same drawing that becomes the PNG.
class PosterPreview extends StatefulWidget {
  const PosterPreview({super.key, required this.prepared});
  final PreparedPoster prepared;

  @override
  State<PosterPreview> createState() => _PosterPreviewState();
}

class _PosterPreviewState extends State<PosterPreview> {
  ui.Picture? _pic;
  PreparedPoster? _for;

  ui.Picture _picture() {
    if (_pic == null || !identical(_for, widget.prepared)) {
      _pic?.dispose();
      _pic = recordPoster(widget.prepared);
      _for = widget.prepared;
    }
    return _pic!;
  }

  @override
  void dispose() {
    _pic?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
        child: CustomPaint(
          painter: _PicturePainter(_picture(), widget.prepared.size),
          child: const SizedBox.expand(),
        ),
      );
}

class _PicturePainter extends CustomPainter {
  _PicturePainter(this.pic, this.card);
  final ui.Picture pic;
  final Size card;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / card.width, size.height / card.height);
    canvas.drawPicture(pic);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PicturePainter old) => !identical(old.pic, pic);
}

// ───────────────────────────── pieces ───────────────────────────────────

/// A large labelled button: at least 64 dp tall, its words wrap rather
/// than shrink when the phone's text is large.
class BigButton extends StatelessWidget {
  const BigButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.color,
    this.outlined = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final Color? color;
  final bool outlined;

  @override
  Widget build(BuildContext context) {
    final text = Text(label,
        textAlign: TextAlign.center,
        softWrap: true,
        style: NeonType.manrope(NeonType.rowTitle + 1, FontWeight.w700));
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(16));
    const pad = EdgeInsets.symmetric(horizontal: 18, vertical: 14);
    final child = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 26),
        const SizedBox(width: 10),
        Flexible(child: text),
      ],
    );
    final button = outlined
        ? OutlinedButton(
            onPressed: onPressed,
            style: OutlinedButton.styleFrom(
              foregroundColor: Neon.textHi,
              side: BorderSide(color: Neon.lineBright, width: 1.4),
              shape: shape,
              padding: pad,
              minimumSize: const Size(64, 64),
            ),
            child: child,
          )
        : FilledButton(
            onPressed: onPressed,
            style: FilledButton.styleFrom(
              backgroundColor: color ?? Neon.accentFill,
              foregroundColor: color != null ? Neon.textOn(color!) : Neon.onAccent,
              shape: shape,
              padding: pad,
              minimumSize: const Size.fromHeight(64),
            ),
            child: child,
          );
    return ConstrainedBox(constraints: const BoxConstraints(minHeight: 64, minWidth: 64), child: button);
  }
}

class _ChoiceChip extends StatelessWidget {
  const _ChoiceChip({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 64, minWidth: 64),
        child: OutlinedButton.icon(
          onPressed: onTap,
          icon: Icon(selected ? Icons.check_circle_rounded : Icons.circle_outlined, size: 24),
          label: Text(label,
              textAlign: TextAlign.center,
              style: NeonType.manrope(NeonType.rowTitle, FontWeight.w600)),
          style: OutlinedButton.styleFrom(
            foregroundColor: selected ? Neon.violet : Neon.textHi,
            backgroundColor: selected ? Neon.violet.withValues(alpha: 0.1) : null,
            side: BorderSide(color: selected ? Neon.violet : Neon.lineBright, width: selected ? 2 : 1.2),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            minimumSize: const Size(64, 64),
          ),
        ),
      );
}

class _ColourChip extends StatelessWidget {
  const _ColourChip({
    required this.colour,
    required this.palette,
    required this.selected,
    required this.onTap,
  });
  final String colour;
  final PosterPalette palette;
  final bool selected;
  final VoidCallback onTap;

  static const _names = {
    'gold': 'Gold',
    'pink': 'Pink',
    'blue': 'Blue',
    'green': 'Green',
    'white': 'White',
    'purple': 'Purple',
  };

  @override
  Widget build(BuildContext context) => ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 64, minWidth: 64),
        child: OutlinedButton(
          onPressed: onTap,
          style: OutlinedButton.styleFrom(
            foregroundColor: Neon.textHi,
            side: BorderSide(color: selected ? Neon.violet : Neon.lineBright, width: selected ? 2.4 : 1.2),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            minimumSize: const Size(64, 64),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(colors: [palette.swatch, palette.petal]),
                  border: Border.all(color: palette.foilMid, width: 2),
                ),
                child: selected ? Icon(Icons.check_rounded, size: 18, color: Neon.glyphOn(palette.swatch)) : null,
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(_names[colour] ?? colour,
                    style: NeonType.manrope(NeonType.rowTitle, FontWeight.w600)),
              ),
            ],
          ),
        ),
      );
}

class _LineTile extends StatelessWidget {
  const _LineTile({required this.field, required this.value, required this.onTap});
  final String field;
  final String value;
  final VoidCallback onTap;

  static const _labels = {
    'headline': 'Heading',
    'name': 'Name',
    'age': 'Age',
    'message': 'Wishes',
    'from': 'From',
    'date': 'Date',
  };

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Material(
          color: Neon.surface,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 64),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_labels[field] ?? field,
                              style: TextStyle(color: Neon.textLo, fontSize: NeonType.footnote)),
                          const SizedBox(height: 2),
                          Text(
                            value.isEmpty ? 'Tap to add' : value,
                            style: TextStyle(
                              color: value.isEmpty ? Neon.textDim : Neon.textHi,
                              fontSize: NeonType.rowTitle + 1,
                              height: 1.3,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.edit_rounded, color: Neon.textLo),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
}

class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: Neon.surface,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              Icon(icon, size: 22, color: Neon.textLo),
              const SizedBox(width: 10),
              Expanded(
                child: Text(text, style: TextStyle(color: Neon.textHi, fontSize: NeonType.callout)),
              ),
            ],
          ),
        ),
      );
}

class _NeedCard extends StatelessWidget {
  const _NeedCard({
    required this.text,
    required this.onFix,
    this.action = 'Change it',
    this.icon = Icons.edit_rounded,
  });
  final String text;
  final VoidCallback onFix;
  final String action;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Neon.warning.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Neon.warning.withValues(alpha: 0.5)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(text, style: TextStyle(color: Neon.textHi, fontSize: NeonType.rowTitle, height: 1.35)),
              const SizedBox(height: 10),
              BigButton(icon: icon, label: action, onPressed: onFix, outlined: true),
            ],
          ),
        ),
      );
}

/// Nudges the photo in its frame with big arrows — easier than a pinch for
/// shaky hands. Each tap is one small step, shown at once.
class _MovePanel extends StatelessWidget {
  const _MovePanel({required this.controller});
  final PosterController controller;

  void _nudge({double dx = 0, double dy = 0, double dz = 0, bool reset = false}) {
    final before = controller.spec.photoFocus;
    final next = reset
        ? PhotoFocus.centre
        : before.copyWith(x: before.x + dx, y: before.y + dy, zoom: before.zoom + dz);
    controller.previewFocus(next);
    controller.commitFocus(before);
  }

  @override
  Widget build(BuildContext context) {
    Widget b(IconData i, String label, VoidCallback f) =>
        BigButton(icon: i, label: label, onPressed: f, outlined: true);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          b(Icons.arrow_upward_rounded, 'Up', () => _nudge(dy: 0.06)),
          b(Icons.arrow_downward_rounded, 'Down', () => _nudge(dy: -0.06)),
          b(Icons.arrow_back_rounded, 'Left', () => _nudge(dx: 0.06)),
          b(Icons.arrow_forward_rounded, 'Right', () => _nudge(dx: -0.06)),
          b(Icons.zoom_in_rounded, 'Closer', () => _nudge(dz: 0.15)),
          b(Icons.zoom_out_rounded, 'Further', () => _nudge(dz: -0.15)),
          b(Icons.center_focus_strong_rounded, 'Whole photo', () => _nudge(reset: true)),
        ],
      ),
    );
  }
}

/// Every design, drawn small with his own words and photo, to pick by eye.
class _DesignCarousel extends StatefulWidget {
  const _DesignCarousel({required this.controller});
  final PosterController controller;

  @override
  State<_DesignCarousel> createState() => _DesignCarouselState();
}

class _DesignCarouselState extends State<_DesignCarousel> {
  final Map<String, ui.Picture> _cache = {};
  Object? _cacheFor;

  @override
  void dispose() {
    for (final p in _cache.values) {
      p.dispose();
    }
    super.dispose();
  }

  ui.Picture _thumb(PosterTemplate t) {
    final c = widget.controller;
    final s = c.scene;
    final key = Object.hash(s.spec.printedHeadline, s.spec.name, s.spec.message, s.spec.from,
        s.spec.colourCustom ? s.spec.colour : '', s.spec.format, s.photo, s.tint);
    if (key != _cacheFor) {
      for (final p in _cache.values) {
        p.dispose();
      }
      _cache.clear();
      _cacheFor = key;
    }
    return _cache[t.id] ??= recordPoster(preparePoster(PosterScene(
      spec: s.spec.copyWith(
        design: t.id,
        colour: s.spec.colourCustom ? s.spec.colour : designHomeColour[t.id],
        signature: false,
      ),
      photo: s.photo,
      tint: s.tint,
      seed: s.seed,
    )));
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final px = posterPixels(c.spec.format);
    const h = 190.0;
    final w = h * px.w / px.h;
    return SizedBox(
      height: h + 64,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: posterTemplateList.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (context, i) {
          final t = posterTemplateList[i];
          final selected = c.spec.design == t.id;
          return Semantics(
            button: true,
            selected: selected,
            label: t.title,
            child: GestureDetector(
              onTap: () => c.apply(PosterChange(design: t.id)),
              child: SizedBox(
                width: w + 8,
                child: Column(
                  children: [
                    Container(
                      width: w + 8,
                      height: h + 8,
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color: selected ? Neon.violet : Colors.transparent, width: 3),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: CustomPaint(
                          painter: _PicturePainter(_thumb(t), Size(px.w.toDouble(), px.h.toDouble())),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Expanded(
                      child: Text(t.title,
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.fade,
                          style: TextStyle(
                            color: selected ? Neon.violet : Neon.textHi,
                            fontSize: NeonType.body,
                            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                          )),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// One line's own editor: big letters, the keyboard's mic works here, and
/// the count shows how much room is left (never a hard stop — over the
/// limit he is asked to shorten it).
class _LineEditor extends StatefulWidget {
  const _LineEditor({required this.field, required this.initial, this.hint});
  final String field;
  final String initial;

  /// Shown faintly in an empty box (the heading the card prints by itself).
  final String? hint;

  @override
  State<_LineEditor> createState() => _LineEditorState();
}

class _LineEditorState extends State<_LineEditor> {
  late final _text = TextEditingController(text: widget.initial);

  static const _titles = {
    'headline': 'The heading',
    'name': 'The name, as it should be written',
    'age': 'The age',
    'message': 'Your wishes',
    'from': 'Who it is from',
    'date': 'The date',
  };

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final limit = posterLimits[widget.field];
    final isAge = widget.field == 'age';
    // Counted as the server counts (posterTextLength), so "60 of 60" here
    // is never "too long" a moment later.
    final len = posterTextLength(cleanLine(widget.field, _text.text));
    return AlertDialog(
      backgroundColor: Neon.surface,
      title: Text(_titles[widget.field] ?? widget.field,
          style: NeonType.manrope(NeonType.title3, FontWeight.w700).copyWith(color: Neon.textHi)),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _text,
              autofocus: true,
              minLines: widget.field == 'message' ? 4 : 1,
              maxLines: widget.field == 'message' ? 8 : 2,
              keyboardType: isAge
                  ? TextInputType.number
                  : (widget.field == 'message' ? TextInputType.multiline : TextInputType.text),
              inputFormatters: isAge ? [FilteringTextInputFormatter.digitsOnly] : null,
              textCapitalization: TextCapitalization.sentences,
              style: TextStyle(color: Neon.textHi, fontSize: 22, height: 1.35),
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                filled: true,
                fillColor: Neon.surfaceHigh,
                hintText: widget.hint,
                hintStyle: TextStyle(color: Neon.textDim, fontSize: 22, height: 1.35),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
              ),
            ),
            if (limit != null) ...[
              const SizedBox(height: 8),
              Text(
                len > limit
                    ? 'A little long — please shorten it to $limit letters.'
                    : '$len of $limit letters',
                style: TextStyle(
                    color: len > limit ? Neon.warningInk : Neon.textLo,
                    fontSize: NeonType.callout),
              ),
            ],
            if (widget.field == 'headline') ...[
              const SizedBox(height: 6),
              Text('Leave it empty to keep the usual heading.',
                  style: TextStyle(color: Neon.textLo, fontSize: NeonType.callout)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel', style: TextStyle(fontSize: 18)),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_text.text),
          style: FilledButton.styleFrom(minimumSize: const Size(96, 52)),
          child: const Text('Save', style: TextStyle(fontSize: 18)),
        ),
      ],
    );
  }
}

// ───────────────────────────── the voice bar ────────────────────────────

/// The mic, on the card screen itself: this full-screen page covers the
/// Home orb, and he should be able to say "make the letters bigger" without
/// leaving it. Captions show what was heard and said.
class PosterVoiceBar extends StatelessWidget {
  const PosterVoiceBar({super.key});

  @override
  Widget build(BuildContext context) {
    final engine = AssistantEngine.instance;
    return ListenableBuilder(
      listenable: engine,
      builder: (context, _) {
        final on = engine.inlineVoice || engine.liveActive;
        return Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          decoration: BoxDecoration(
            color: Neon.surface,
            border: Border(top: BorderSide(color: Neon.line)),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 72,
                height: 72,
                child: FilledButton(
                  onPressed: () => on ? engine.endInlineConversation() : engine.beginInlineConversation(),
                  style: FilledButton.styleFrom(
                    shape: const CircleBorder(),
                    padding: EdgeInsets.zero,
                    backgroundColor: on ? Neon.error : Neon.accentFill,
                    foregroundColor: on ? Neon.glyphOn(Neon.error) : Neon.onAccent,
                  ),
                  child: Icon(on ? Icons.stop_rounded : Icons.mic_rounded, size: 34,
                      semanticLabel: on ? 'Stop talking' : 'Talk'),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: ValueListenableBuilder<CaptionLine?>(
                  valueListenable: engine.caption,
                  builder: (context, line, _) => Text(
                    line?.text.isNotEmpty == true
                        ? line!.text
                        : (on
                            ? 'Listening… say what to change.'
                            : 'Tap the mic and say what to change — "bigger letters", "pink", "send it".'),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Neon.textHi, fontSize: NeonType.callout, height: 1.3),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// A block's rect on the card, for tests.
@visibleForTesting
Rect? posterBlockRect(PosterLayout l, String field) => l.block(field)?.rect;
