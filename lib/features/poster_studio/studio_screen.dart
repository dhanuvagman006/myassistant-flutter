import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../design/apple_kit.dart';
import '../../design/motion.dart';
import '../../design/neon_tokens.dart';
import '../../design/neon_widgets.dart';
import '../../services/app_feedback.dart';
import '../poster/photo_source_sheet.dart';
import '../poster/poster_controller.dart' show PickedPhoto, PhotoAccessDenied;
import '../poster/poster_share.dart';
import 'studio_controller.dart';
import 'studio_models.dart';
import 'studio_painter.dart';
import 'studio_palettes.dart';
import 'studio_templates.dart';

/// Picks a photo: 'gallery' or 'camera' (a fake in tests).
typedef StudioPhotoPicker = Future<PickedPhoto?> Function(BuildContext context, String source);

/// ─────────────────────────────────────────────────────────────────────────
///  POSTER STUDIO (2026-09-30). The poster, large, exactly as it will be
///  sent; six tools under it (Regenerate, Style, Colours, Edit text,
///  Change image, Variation); the lines the server could not fill asked
///  as "Add location?"; and one glowing button that sends it. The words
///  are always his, set by the phone — the AI only paints the picture.
/// ─────────────────────────────────────────────────────────────────────────
class PosterStudioScreen extends StatefulWidget {
  const PosterStudioScreen({super.key, this.controller, this.request, this.pickPhoto});

  final PosterStudioController? controller;

  /// Start designing these words at once.
  final String? request;
  final StudioPhotoPicker? pickPhoto;

  /// Open copies (the assistant never stacks a second one).
  static int showing = 0;

  @override
  State<PosterStudioScreen> createState() => _PosterStudioScreenState();
}

class _PosterStudioScreenState extends State<PosterStudioScreen> {
  late final PosterStudioController c = widget.controller ?? PosterStudioController.instance;
  final _ask = TextEditingController();
  StudioFormat _startFormat = StudioFormat.portrait;

  // Students and couples (2026-09-30): six ideas, three shown a day.
  static const _ideas = [
    'College tech fest, 12 Oct, main auditorium',
    'Happy 1st anniversary, Anu — 3 years of us',
    'Farewell party for final years, Friday 6 pm',
    'Hostel Diwali night, Saturday 7 pm',
    'Date night, Saturday 7 pm — dress up, love',
    'Good morning, love — have a great day',
  ];

  /// Three of the six, a different three each day.
  List<String> get _todaysIdeas {
    final now = DateTime.now();
    final start = (now.difference(DateTime(now.year)).inDays * 3) % _ideas.length;
    return [for (var i = 0; i < 3; i++) _ideas[(start + i) % _ideas.length]];
  }

  @override
  void initState() {
    super.initState();
    PosterStudioScreen.showing++;
    c.addListener(_changed);
    unawaited(c.loadBrandColours());
    final r = widget.request?.trim() ?? '';
    if (r.isNotEmpty) {
      _ask.text = r;
      WidgetsBinding.instance.addPostFrameCallback((_) => c.startFromRequest(r));
    }
  }

  @override
  void dispose() {
    PosterStudioScreen.showing--;
    c.removeListener(_changed);
    _ask.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _toast(String text) {
    if (!mounted) return;
    AppFeedback.show(text, context: context);
  }

  // ── build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final started = c.hasPoster || c.designing;
    return NeonScaffold(
      appBar: appleAppBar(context, 'Poster Studio', actions: [
        if (c.hasPoster)
          IconButton(
            tooltip: 'Start a new poster',
            icon: const Icon(Icons.note_add_rounded),
            onPressed: c.busy ? null : _newPoster,
          ),
      ]),
      body: SafeArea(
        top: false,
        child: started ? _studio(context) : _start(context),
      ),
    );
  }

  Widget _studio(BuildContext context) {
    final prompts = c.prompts;
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
            children: [
              _previewBox(context),
              const SizedBox(height: 14),
              if (c.notice != null) ...[
                _NoticeCard(text: c.notice!, onClose: c.dismissNotice),
                const SizedBox(height: 10),
              ],
              for (final n in c.needs.take(1)) ...[
                _NeedCard(field: n, onFix: _editText),
                const SizedBox(height: 10),
              ],
              if (prompts.isNotEmpty) ...[
                const GroupLabel('Still to add'),
                Wrap(
                  spacing: 8,
                  runSpacing: 2,
                  children: [
                    for (final p in prompts)
                      NeonPill(
                        label: p.label,
                        icon: Icons.add_rounded,
                        tone: NeonTone.warning,
                        onPressed: () => _answer(p),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
              ],
              _tools(),
            ],
          ),
        ),
        _ShareBar(
          busy: c.busy,
          onShare: c.hasPoster && !c.designing ? () => _share() : null,
          onMore: c.hasPoster && !c.designing ? _shareOptions : null,
        ),
      ],
    );
  }

  Widget _previewBox(BuildContext context) {
    final size = (c.prepared?.size ?? c.design.format.size);
    final ratio = size.width / size.height;
    return LayoutBuilder(builder: (context, box) {
      final maxH = MediaQuery.sizeOf(context).height * 0.54;
      final w = (maxH * ratio).clamp(0.0, box.maxWidth);
      final p = c.prepared;
      final label = c.designing
          ? 'Designing your poster…'
          : c.generating
              ? 'Painting a new background…'
              : null;
      return Center(
        child: SizedBox(
          width: w,
          height: w / ratio,
          child: Semantics(
            image: true,
            label: p == null ? 'Poster preview, being designed' : 'Poster preview. ${describeStudio(c.design)}',
            child: ExcludeSemantics(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: Neon.halo(c.palette.primary, strength: 0.5),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (p != null)
                        StudioPreview(prepared: p)
                      else
                        ColoredBox(color: Neon.surface),
                      if (label != null) ...[
                        const _Shimmer(),
                        // The loader on its own dark glass, so its words
                        // read over any poster.
                        Center(
                          child: Container(
                            margin: const EdgeInsets.all(16),
                            padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
                            decoration: BoxDecoration(
                              color: Neon.surface.withValues(alpha: 0.9),
                              borderRadius: BorderRadius.circular(Neon.rLg),
                              border: Border.all(color: Neon.lineBright),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                NeonLoader(size: 40, semanticLabel: label),
                                const SizedBox(height: 10),
                                Text(label,
                                    textAlign: TextAlign.center,
                                    style: NeonType.manrope(NeonType.body, FontWeight.w600)
                                        .copyWith(color: Neon.textHi)),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    });
  }

  Widget _tools() {
    final tools = [
      _Tool(
        icon: Icons.auto_awesome_rounded,
        label: c.generating ? 'Painting…' : 'Regenerate',
        tone: NeonTone.discovery,
        busy: c.generating,
        onTap: c.generating ? null : () => unawaited(c.newPicture()),
      ),
      _Tool(icon: Icons.dashboard_customize_rounded, label: 'Style', onTap: _styleSheet),
      _Tool(icon: Icons.palette_rounded, label: 'Colours', onTap: _colourSheet),
      _Tool(icon: Icons.edit_note_rounded, label: 'Edit text', onTap: _editText),
      _Tool(icon: Icons.add_photo_alternate_rounded, label: 'Change image', onTap: _imageSheet),
      _Tool(icon: Icons.shuffle_rounded, label: 'Variation', tone: NeonTone.tip, onTap: c.variation),
    ];
    return LayoutBuilder(builder: (context, box) {
      final w = (box.maxWidth - 20) / 3;
      return Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [for (final t in tools) SizedBox(width: w, child: t)],
      );
    });
  }

  Widget _start(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Text('Make an event poster',
            style: NeonType.manrope(NeonType.title2, FontWeight.w800).copyWith(color: Neon.textHi)),
        const SizedBox(height: 6),
        Text(
          'Tell me about the event. The words are set exactly as you write them, '
          'over a fresh background.',
          style: NeonType.manrope(NeonType.body, FontWeight.w500).copyWith(color: Neon.textLo),
        ),
        const SizedBox(height: 16),
        if (c.notice != null) ...[
          _NoticeCard(text: c.notice!, onClose: c.dismissNotice),
          const SizedBox(height: 12),
        ],
        GlowCard(
          tone: NeonTone.brand,
          halo: 0.5,
          padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
          child: TextField(
            controller: _ask,
            minLines: 3,
            maxLines: 6,
            textCapitalization: TextCapitalization.sentences,
            style: NeonType.manrope(NeonType.rowTitle, FontWeight.w600).copyWith(color: Neon.textHi),
            decoration: const InputDecoration(
              labelText: "What's the event?",
              hintText: 'Name, day, time and place',
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
            ),
          ),
        ),
        const SizedBox(height: 14),
        const GroupLabel('Size'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final f in StudioFormat.values)
              _Choice(
                label: f.label,
                selected: _startFormat == f,
                onTap: () => setState(() => _startFormat = f),
              ),
          ],
        ),
        const SizedBox(height: 18),
        _PrimaryButton(
          label: 'Design my poster',
          icon: Icons.auto_awesome_rounded,
          onPressed: () {
            final t = _ask.text.trim();
            if (t.isEmpty) {
              _toast('Type what the event is first.');
              return;
            }
            FocusScope.of(context).unfocus();
            unawaited(c.startFromRequest(t, format: _startFormat));
          },
        ),
        const SizedBox(height: 10),
        Center(
          child: NeonPill(
            label: "I'll type the words myself",
            icon: Icons.edit_note_rounded,
            tone: NeonTone.info,
            onPressed: () {
              c.setFormat(_startFormat);
              _editText();
            },
          ),
        ),
        const SizedBox(height: 18),
        const GroupLabel('Ideas'),
        Wrap(
          spacing: 8,
          runSpacing: 2,
          children: [
            for (final idea in _todaysIdeas)
              NeonPill(
                label: idea,
                tone: NeonTone.tip,
                inkOverride: Neon.textHi,
                onPressed: () => setState(() => _ask.text = idea),
              ),
          ],
        ),
      ],
    );
  }

  // ── actions ────────────────────────────────────────────────────────────

  void _newPoster() {
    c.clear();
    _ask.clear();
  }

  Future<void> _share({String app = 'whatsapp'}) async {
    final needs = c.needs;
    if (needs.isNotEmpty) {
      _toast('Please shorten the ${needs.first.label.toLowerCase()} first.');
      await _editText();
      return;
    }
    final out = await c.share(app: app);
    if (out == ShareOutcome.failed) _toast("The poster couldn't be shared just now. Please try again.");
  }

  Future<void> _save() async {
    if (c.needs.isNotEmpty) {
      _toast('Please shorten the ${c.needs.first.label.toLowerCase()} first.');
      return;
    }
    final out = await c.saveToPhotos();
    if (out == ShareOutcome.saved) _toast('Saved to your Photos.');
    if (out == ShareOutcome.failed) _toast("The poster couldn't be saved just now.");
  }

  Future<void> _shareOptions() async {
    final pick = await showAppSheet<String>(
      context: context,
      useRootNavigator: true,
      backgroundColor: Neon.surface,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _sheetTitle('Share or save'),
              _Option(
                icon: Icons.ios_share_rounded,
                colour: Neon.cyan,
                title: 'Other apps',
                subtitle: 'Instagram, email, Telegram…',
                onTap: () => Navigator.pop(ctx, 'any'),
              ),
              const SizedBox(height: 10),
              _Option(
                icon: Icons.download_rounded,
                colour: Neon.lime,
                title: 'Save to my Photos',
                subtitle: 'Keep a copy on this phone',
                onTap: () => Navigator.pop(ctx, 'save'),
              ),
            ],
          ),
        ),
      ),
    );
    if (pick == 'any') await _share(app: 'any');
    if (pick == 'save') await _save();
  }

  Future<void> _answer(StudioPrompt p) async {
    final r = await showAppSheet<String>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      backgroundColor: Neon.surface,
      showDragHandle: true,
      builder: (ctx) => _AnswerSheet(prompt: p),
    );
    if (r == null) return;
    if (r == _AnswerSheet.skip) {
      c.skip(p);
    } else if (r.trim().isNotEmpty) {
      c.answer(p, r);
    }
  }

  Future<void> _editText() async {
    final values = await showAppSheet<Map<StudioField, String>>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      backgroundColor: Neon.surface,
      showDragHandle: true,
      builder: (ctx) => _EditSheet(
        design: c.design,
        missing: {for (final p in c.prompts) if (p.field != StudioField.details) p.field},
      ),
    );
    if (values != null) c.setAll(values);
  }

  Future<void> _styleSheet() => showAppSheet<void>(
        context: context,
        isScrollControlled: true,
        useRootNavigator: true,
        backgroundColor: Neon.surface,
        showDragHandle: true,
        builder: (ctx) => _StyleSheet(controller: c),
      );

  Future<void> _colourSheet() => showAppSheet<void>(
        context: context,
        isScrollControlled: true,
        useRootNavigator: true,
        backgroundColor: Neon.surface,
        showDragHandle: true,
        builder: (ctx) => _ColourSheet(controller: c),
      );

  Future<void> _imageSheet() async {
    final pick = await showAppSheet<String>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      backgroundColor: Neon.surface,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _sheetTitle('Change image'),
              _Option(
                icon: Icons.auto_awesome_rounded,
                colour: Neon.violet,
                title: 'New AI background',
                subtitle: c.aiOff ? 'AI pictures were off — tap to try again' : 'A fresh picture, with no words in it',
                onTap: () => Navigator.pop(ctx, 'ai'),
              ),
              const SizedBox(height: 10),
              _Option(
                icon: Icons.photo_library_rounded,
                colour: Neon.cyan,
                title: 'Use a photo from my phone',
                onTap: () => Navigator.pop(ctx, 'gallery'),
              ),
              const SizedBox(height: 10),
              _Option(
                icon: Icons.photo_camera_rounded,
                colour: Neon.pink,
                title: 'Take a photo',
                onTap: () => Navigator.pop(ctx, 'camera'),
              ),
              const SizedBox(height: 10),
              _Option(
                icon: Icons.gradient_rounded,
                colour: Neon.lime,
                title: 'Drawn background',
                subtitle: "The style's own art, no picture",
                onTap: () => Navigator.pop(ctx, 'art'),
              ),
              const SizedBox(height: 18),
              const GroupLabel('Logo'),
              _Option(
                icon: Icons.verified_rounded,
                colour: Neon.accentD,
                title: c.logo == null ? 'Add a logo or small photo' : 'Change the logo',
                onTap: () => Navigator.pop(ctx, 'logo'),
              ),
              if (c.logo != null) ...[
                const SizedBox(height: 10),
                _Option(
                  icon: Icons.hide_image_rounded,
                  colour: Neon.error,
                  title: 'Remove the logo',
                  onTap: () => Navigator.pop(ctx, 'nologo'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    switch (pick) {
      case 'ai':
        unawaited(c.newPicture());
      case 'gallery' || 'camera':
        final photo = await _pick(pick!);
        if (photo != null) await c.usePhoto(photo);
      case 'art':
        c.useDrawnArt();
      case 'logo':
        final photo = await _pick('ask');
        if (photo != null) await c.setLogo(photo);
      case 'nologo':
        await c.setLogo(null);
    }
  }

  Future<PickedPhoto?> _pick(String source) async {
    if (!mounted) return null;
    try {
      final picker = widget.pickPhoto;
      return picker != null ? await picker(context, source) : await PhotoSourceSheet.pick(context, source);
    } on PhotoAccessDenied {
      return null; // the sheet already showed the way to Settings
    } catch (_) {
      _toast("That photo couldn't be opened. Please try another.");
      return null;
    }
  }
}

// ───────────────────────────── the preview ────────────────────────────────

/// The poster, recorded once per layout and replayed at the preview's size.
class StudioPreview extends StatefulWidget {
  const StudioPreview({super.key, required this.prepared});
  final PreparedStudio prepared;

  @override
  State<StudioPreview> createState() => _StudioPreviewState();
}

class _StudioPreviewState extends State<StudioPreview> {
  ui.Picture? _pic;
  PreparedStudio? _for;

  ui.Picture _picture() {
    if (_pic == null || !identical(_for, widget.prepared)) {
      _pic?.dispose();
      _pic = recordStudio(widget.prepared);
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
  _PicturePainter(this.pic, this.poster);
  final ui.Picture pic;
  final Size poster;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / poster.width, size.height / poster.height);
    canvas.drawPicture(pic);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PicturePainter old) => !identical(old.pic, pic);
}

/// A slow band of light across the preview while a picture is painted;
/// with "Remove animations" on, a still veil.
class _Shimmer extends StatefulWidget {
  const _Shimmer();
  @override
  State<_Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<_Shimmer> with SingleTickerProviderStateMixin {
  late final AnimationController _t =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (Motion.reduced(context)) {
      _t.stop();
    } else if (!_t.isAnimating) {
      _t.repeat();
    }
  }

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final veil = Neon.bg.withValues(alpha: 0.5);
    if (Motion.reduced(context)) return ColoredBox(color: veil);
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _t,
        builder: (context, _) {
          final x = -1.8 + 3.6 * _t.value;
          return DecoratedBox(
            decoration: BoxDecoration(
              color: veil,
              gradient: LinearGradient(
                begin: Alignment(x - 0.7, -0.4),
                end: Alignment(x + 0.7, 0.4),
                colors: [
                  veil,
                  Color.alphaBlend(Neon.cyan.withValues(alpha: 0.16), veil),
                  veil,
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

// ───────────────────────────── pieces ─────────────────────────────────────

Widget _sheetTitle(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(text,
          style: NeonType.manrope(NeonType.title3, FontWeight.w700).copyWith(color: Neon.textHi)),
    );

/// The one strong action: the brand gradient with its full glow.
class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({required this.label, required this.icon, required this.onPressed, this.busy = false});
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !busy;
    final ink = Neon.onBrand;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      excludeSemantics: true,
      onTap: enabled ? onPressed : null,
      child: Opacity(
        opacity: enabled || busy ? 1 : 0.5,
        child: Tappable(
          onTap: enabled ? onPressed : null,
          semanticLabel: label,
          child: Container(
            constraints: const BoxConstraints(minHeight: 58),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            decoration: BoxDecoration(
              gradient: Neon.gBrand,
              borderRadius: BorderRadius.circular(18),
              boxShadow: enabled ? Neon.halo(Neon.violet, strength: 1) : null,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (busy)
                  NeonLoader.inline(size: 20, semanticLabel: label)
                else
                  Icon(icon, color: ink, size: 24),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(label,
                      textAlign: TextAlign.center,
                      style: NeonType.manrope(NeonType.rowTitle + 1, FontWeight.w800).copyWith(color: ink)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Sends the poster, always in reach under the scroll.
class _ShareBar extends StatelessWidget {
  const _ShareBar({required this.busy, required this.onShare, required this.onMore});
  final bool busy;
  final VoidCallback? onShare;
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: Neon.bg.withValues(alpha: 0.72),
          border: Border(top: BorderSide(color: Neon.line)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Row(
            children: [
              Expanded(
                child: _PrimaryButton(
                  label: 'Share on WhatsApp',
                  icon: Icons.send_rounded,
                  busy: busy,
                  onPressed: onShare,
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 58,
                height: 58,
                child: GlowCard(
                  tone: NeonTone.info,
                  halo: 0,
                  rimWidth: 1.4,
                  radius: 18,
                  onTap: busy ? null : onMore,
                  semanticLabel: 'More ways to share or save',
                  child: Center(child: Icon(Icons.more_horiz_rounded, color: Neon.textHi)),
                ),
              ),
            ],
          ),
        ),
      );
}

/// One studio tool: a quiet lit tile.
class _Tool extends StatelessWidget {
  const _Tool({required this.icon, required this.label, required this.onTap, this.tone = NeonTone.info, this.busy = false});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final NeonTone tone;
  final bool busy;

  @override
  Widget build(BuildContext context) => GlowCard(
        tone: tone,
        halo: 0,
        rimWidth: 1.2,
        radius: Neon.rMd,
        minHeight: 78,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
        onTap: onTap,
        semanticLabel: label,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (busy) NeonLoader.inline(size: 24, semanticLabel: label) else Icon(icon, size: 26, color: tone.ink),
            const SizedBox(height: 6),
            Text(label,
                textAlign: TextAlign.center,
                softWrap: true,
                style: NeonType.manrope(NeonType.footnote, FontWeight.w700).copyWith(color: Neon.textHi)),
          ],
        ),
      );
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({required this.text, required this.onClose});
  final String text;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => GlowCard(
        tone: NeonTone.info,
        halo: 0,
        rimWidth: 1.2,
        padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
        child: Row(
          children: [
            Icon(Icons.info_outline_rounded, color: NeonTone.info.ink, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Text(text,
                  style: NeonType.manrope(NeonType.body, FontWeight.w600).copyWith(color: Neon.textHi)),
            ),
            IconButton(
              tooltip: 'Dismiss',
              icon: Icon(Icons.close_rounded, color: Neon.textLo),
              onPressed: onClose,
            ),
          ],
        ),
      );
}

class _NeedCard extends StatelessWidget {
  const _NeedCard({required this.field, required this.onFix});
  final StudioField field;
  final VoidCallback onFix;

  @override
  Widget build(BuildContext context) => GlowCard(
        tone: NeonTone.warning,
        halo: 0.35,
        padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
        child: Row(
          children: [
            Icon(Icons.short_text_rounded, color: NeonTone.warning.ink, size: 24),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'The ${field.label.toLowerCase()} is a little long for this poster. '
                'Please make it shorter — nothing was cut.',
                style: NeonType.manrope(NeonType.body, FontWeight.w600).copyWith(color: Neon.textHi),
              ),
            ),
            NeonPill(label: 'Edit', tone: NeonTone.warning, onPressed: onFix),
          ],
        ),
      );
}

class _Choice extends StatelessWidget {
  const _Choice({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        selected: selected,
        child: NeonPill(
          label: label,
          icon: selected ? Icons.check_rounded : null,
          tone: selected ? NeonTone.brand : NeonTone.info,
          inkOverride: selected ? null : Neon.textHi,
          onPressed: onTap,
        ),
      );
}

class _Option extends StatelessWidget {
  const _Option({required this.icon, required this.colour, required this.title, this.subtitle, required this.onTap});
  final IconData icon;
  final Color colour;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GlowCard(
        tone: NeonTone.info,
        halo: 0,
        rimWidth: 1.2,
        minHeight: 60,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        onTap: onTap,
        semanticLabel: title,
        child: Row(
          children: [
            IconTile(icon, colour, size: 38),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title,
                      style: NeonType.manrope(NeonType.rowTitle, FontWeight.w700).copyWith(color: Neon.textHi)),
                  if (subtitle != null)
                    Text(subtitle!,
                        style: NeonType.manrope(NeonType.footnote, FontWeight.w500).copyWith(color: Neon.textLo)),
                ],
              ),
            ),
          ],
        ),
      );
}

/// One line's editor. A line the design could not fill is lit amber and
/// asks for itself ("Add location?").
class _FieldEditor extends StatelessWidget {
  const _FieldEditor({required this.field, required this.controller, required this.missing});
  final StudioField field;
  final TextEditingController controller;
  final bool missing;

  @override
  Widget build(BuildContext context) {
    final amber = NeonTone.warning.ink;
    final multi = field == StudioField.details;
    return TextField(
      controller: controller,
      minLines: multi ? 2 : 1,
      maxLines: multi ? 6 : (field == StudioField.title ? 3 : 2),
      textCapitalization: TextCapitalization.sentences,
      style: NeonType.manrope(NeonType.rowTitle, field == StudioField.title ? FontWeight.w800 : FontWeight.w600)
          .copyWith(color: Neon.textHi),
      decoration: InputDecoration(
        labelText: field.label,
        hintText: field.hint,
        helperText: multi ? 'One detail per line' : (missing ? 'Add ${field.label.toLowerCase()}?' : null),
        helperStyle: missing ? TextStyle(color: amber) : null,
        prefixIcon: missing ? Icon(Icons.add_circle_outline_rounded, color: amber) : null,
        enabledBorder: missing
            ? OutlineInputBorder(
                borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: amber, width: 1.6))
            : null,
      ),
    );
  }
}

// ───────────────────────────── the sheets ─────────────────────────────────

/// "Add location?": one line, answered or left off. Owns its field, so
/// it outlives the sheet's closing slide.
class _AnswerSheet extends StatefulWidget {
  const _AnswerSheet({required this.prompt});
  final StudioPrompt prompt;

  /// Popped for "Leave it off".
  static const skip = '\u0000skip';

  @override
  State<_AnswerSheet> createState() => _AnswerSheetState();
}

class _AnswerSheetState extends State<_AnswerSheet> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.prompt;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _sheetTitle(p.label),
              TextField(
                controller: _text,
                autofocus: true,
                textCapitalization: TextCapitalization.sentences,
                style: NeonType.manrope(NeonType.rowTitle, FontWeight.w600).copyWith(color: Neon.textHi),
                decoration: InputDecoration(
                  labelText: p.field == StudioField.details ? p.label.replaceAll('?', '') : p.field.label,
                  hintText: p.field.hint,
                ),
                onSubmitted: (v) => Navigator.pop(context, v),
              ),
              const SizedBox(height: 14),
              _PrimaryButton(
                  label: 'Add to poster',
                  icon: Icons.check_rounded,
                  onPressed: () => Navigator.pop(context, _text.text)),
              const SizedBox(height: 6),
              Center(
                child: NeonPill(
                  label: 'Leave it off',
                  tone: NeonTone.info,
                  onPressed: () => Navigator.pop(context, _AnswerSheet.skip),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Every line of the poster, each in its own field; the lines the design
/// could not fill lit amber.
class _EditSheet extends StatefulWidget {
  const _EditSheet({required this.design, required this.missing});
  final EventDesign design;
  final Set<StudioField> missing;

  @override
  State<_EditSheet> createState() => _EditSheetState();
}

class _EditSheetState extends State<_EditSheet> {
  late final _fields = {
    for (final f in StudioField.values) f: TextEditingController(text: widget.design.text(f)),
  };

  @override
  void dispose() {
    for (final t in _fields.values) {
      t.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.86),
          child: SafeArea(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              children: [
                _sheetTitle('Edit text'),
                Text('Every word goes on the poster exactly as you type it.',
                    style: NeonType.manrope(NeonType.footnote, FontWeight.w500).copyWith(color: Neon.textLo)),
                const SizedBox(height: 12),
                for (final f in StudioField.values) ...[
                  _FieldEditor(field: f, controller: _fields[f]!, missing: widget.missing.contains(f)),
                  const SizedBox(height: 12),
                ],
                _PrimaryButton(
                  label: 'Done',
                  icon: Icons.check_rounded,
                  onPressed: () =>
                      Navigator.pop(context, {for (final e in _fields.entries) e.key: e.value.text}),
                ),
              ],
            ),
          ),
        ),
      );
}

class _StyleSheet extends StatefulWidget {
  const _StyleSheet({required this.controller});
  final PosterStudioController controller;
  @override
  State<_StyleSheet> createState() => _StyleSheetState();
}

class _StyleSheetState extends State<_StyleSheet> {
  PosterStudioController get c => widget.controller;
  final Map<String, ({ui.Picture pic, Size size})> _thumbs = {};

  ({ui.Picture pic, Size size}) _thumb(EventTemplate t) => _thumbs.putIfAbsent(t.id, () {
        final palette = t.id == c.template.id || c.paletteChosen ? c.palette : studioPalette(t.palette);
        final p = prepareStudioSync(StudioScene(
          design: c.design,
          template: t,
          palette: palette,
          image: c.image,
          logo: c.logo,
          seed: c.seed,
        ));
        return (pic: recordStudio(p), size: p.size);
      });

  void _clear() {
    for (final t in _thumbs.values) {
      t.pic.dispose();
    }
    _thumbs.clear();
  }

  @override
  void dispose() {
    _clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.86),
      child: SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            _sheetTitle('Style'),
            const GroupLabel('Size'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final f in StudioFormat.values)
                  _Choice(
                    label: f.label,
                    selected: c.design.format == f,
                    onTap: () => setState(() {
                      c.setFormat(f);
                      _clear();
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            const GroupLabel('Templates'),
            LayoutBuilder(builder: (context, box) {
              final w = (box.maxWidth - 12) / 2;
              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final t in studioTemplates)
                    SizedBox(
                      width: w,
                      child: Semantics(
                        selected: c.template.id == t.id,
                        child: GlowCard(
                          tone: c.template.id == t.id ? NeonTone.brand : NeonTone.info,
                          halo: c.template.id == t.id ? 0.8 : 0,
                          rimWidth: c.template.id == t.id ? 2.4 : 1.2,
                          padding: const EdgeInsets.all(8),
                          semanticLabel: '${t.name} style. ${t.blurb}',
                          onTap: () {
                            c.setTemplate(t.id);
                            Navigator.pop(context);
                          },
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Builder(builder: (context) {
                                final th = _thumb(t);
                                return AspectRatio(
                                  aspectRatio: th.size.width / th.size.height,
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(10),
                                    child: CustomPaint(
                                      painter: _PicturePainter(th.pic, th.size),
                                      child: const SizedBox.expand(),
                                    ),
                                  ),
                                );
                              }),
                              const SizedBox(height: 8),
                              Text(t.name,
                                  style: NeonType.manrope(NeonType.body, FontWeight.w800)
                                      .copyWith(color: Neon.textHi)),
                              Text(t.blurb,
                                  style: NeonType.manrope(NeonType.caption, FontWeight.w500)
                                      .copyWith(color: Neon.textLo)),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              );
            }),
          ],
        ),
      ),
    );
  }
}

class _ColourSheet extends StatefulWidget {
  const _ColourSheet({required this.controller});
  final PosterStudioController controller;
  @override
  State<_ColourSheet> createState() => _ColourSheetState();
}

class _ColourSheetState extends State<_ColourSheet> {
  PosterStudioController get c => widget.controller;
  final _hex = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  Widget _row(List<StudioPalette> ps) => Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final p in ps)
            _Swatch(
              palette: p,
              selected: c.palette == p,
              onTap: () => setState(() => c.setPalette(p)),
            ),
        ],
      );

  Future<void> _addBrand() async {
    final colour = parseHex(_hex.text);
    if (colour == null) {
      setState(() => _error = 'Type a colour code like 1E88E5');
      return;
    }
    setState(() => _error = null);
    await c.addBrandColour(colour);
    _hex.clear();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final suggested = c.design.palette;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.86),
        child: SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: [
              _sheetTitle('Colours'),
              if (suggested != null) ...[
                const GroupLabel('Suggested for this event'),
                _row([suggested]),
                const SizedBox(height: 14),
              ],
              const GroupLabel('Palettes'),
              _row(studioPalettes),
              const SizedBox(height: 14),
              const GroupLabel('Your brand'),
              if (c.brandColours.isNotEmpty) ...[
                _row([for (final b in c.brandColours) StudioPalette.fromBrand(b)]),
                const SizedBox(height: 10),
              ],
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _hex,
                      maxLength: 7,
                      style: NeonType.manrope(NeonType.rowTitle, FontWeight.w600).copyWith(color: Neon.textHi),
                      decoration: InputDecoration(
                        labelText: 'Brand colour code',
                        prefixText: '#',
                        hintText: '1E88E5',
                        errorText: _error,
                        counterText: '',
                      ),
                      onSubmitted: (_) => _addBrand(),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: NeonPill(label: 'Use', icon: Icons.add_rounded, onPressed: _addBrand),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A palette as a lit disc of its three colours.
class _Swatch extends StatelessWidget {
  const _Swatch({required this.palette, required this.selected, required this.onTap});
  final StudioPalette palette;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tappable(
        onTap: onTap,
        semanticLabel: '${palette.name} colours${selected ? ', chosen' : ''}',
        child: SizedBox(
          width: 64,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 52,
                height: 52,
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: selected ? Neon.textHi : Neon.line, width: selected ? 3 : 1),
                  boxShadow: selected ? Neon.halo(palette.primary, strength: 0.8) : null,
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: SweepGradient(
                      colors: [palette.primary, palette.secondary, palette.accent, palette.primary],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(palette.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: NeonType.manrope(NeonType.caption, FontWeight.w600).copyWith(color: Neon.textLo)),
            ],
          ),
        ),
      );
}
