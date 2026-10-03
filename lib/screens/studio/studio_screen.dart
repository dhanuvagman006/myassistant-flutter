import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';

import '../../design/apple_kit.dart';
import '../../design/neon_tokens.dart';
import '../../design/neon_widgets.dart';
import '../../widgets/glow_cta.dart';
import '../../features/assistant/widgets/action_cards.dart'
    show DocumentGalleryScreen;
import '../../models/user_document.dart';
import '../../services/api_service.dart';
import '../../services/studio_service.dart';
import 'studio_look_screen.dart';
import '../../services/app_feedback.dart';
import '../../design/motion.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  STYLE STUDIO — the front door.
///
///  Add one photo of yourself, once. After that every look on this screen
///  uses it, so trying on a sherwani is two taps rather than a photo
///  session. The catalogue is whatever the server offers; this screen
///  groups it and gets out of the way.
/// ─────────────────────────────────────────────────────────────────────────
class StudioScreen extends StatefulWidget {
  const StudioScreen({super.key});

  @override
  State<StudioScreen> createState() => _StudioScreenState();
}

class _StudioScreenState extends State<StudioScreen> {
  StudioState? _state;
  String _error = '';
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// [silent] refreshes the data WITHOUT blanking the screen.
  ///
  /// Every action here used to call the plain loader, so adding a photo,
  /// setting a default or finishing a look threw the whole screen away and
  /// replaced it with a centred spinner for the length of a round trip —
  /// the content then reappeared and the scroll position was lost. A
  /// refresh after an action the user just watched succeed should be
  /// invisible; only the very first load has nothing to show yet.
  Future<void> _load({bool silent = false}) async {
    setState(() {
      if (!silent) _loading = true;
      _error = '';
    });
    try {
      final s = await StudioService.load();
      if (!mounted) return;
      setState(() {
        _state = s;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is StudioException && e.message.isNotEmpty
            ? e.message
            : _offline;
      });
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    AppFeedback.show(msg, context: context);
  }

  /* ---------------------------------------------------------------- */
  /* consent                                                          */
  /* ---------------------------------------------------------------- */

  Future<void> _accept() async {
    setState(() => _busy = true);
    try {
      await StudioService.acceptConsent();
      await _load(silent: true);
    } catch (e) {
      _toast(e is StudioException && e.message.isNotEmpty
          ? e.message
          : "Couldn't reach the studio — try again.");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _withdraw() async {
    final yes = await showAppDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Remove your photos?'),
        content: const Text(
            'Your saved photos of yourself will be deleted from the server, '
            'and Style Studio will stop using them. Looks you have already '
            'made stay in your files.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(c, true),
              child: Text('Remove', style: TextStyle(color: Neon.errorInk))),
        ],
      ),
    );
    if (yes != true) return;
    setState(() => _busy = true);
    try {
      final n = await StudioService.withdrawConsent();
      _toast(n == 1 ? '1 photo removed.' : '$n photos removed.');
      await _load(silent: true);
    } catch (e) {
      _toast(e is StudioException && e.message.isNotEmpty
          ? e.message
          : "Couldn't reach the studio — try again.");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /* ---------------------------------------------------------------- */
  /* photos of the user                                               */
  /* ---------------------------------------------------------------- */

  Future<void> _addMyPhoto() async {
    final src = await _pickSource('Add a photo of you');
    if (src == null) return;
    final shot = await ImagePicker().pickImage(
      source: src,
      imageQuality: 92,
      maxWidth: 2400,
      maxHeight: 2400,
    );
    if (shot == null) return;
    setState(() => _busy = true);
    try {
      final bytes = await shot.readAsBytes();
      await StudioService.addPhoto(
        bytes: bytes,
        filename: shot.name.isEmpty ? 'me.jpg' : shot.name,
        mimeType: shot.mimeType ?? 'image/jpeg',
        role: 'model',
        makeDefault: true,
      );
      await _load(silent: true);
    } catch (e) {
      _toast(e is StudioException ? e.message : "Couldn't save that photo.");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // The theme's sheet and the app's rows (2026-09-30).
  Future<ImageSource?> _pickSource(String title) => showAppSheet<ImageSource>(
        context: context,
        builder: (c) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(title,
                      style: TextStyle(
                          color: Neon.textHi,
                          fontSize: 17,
                          fontWeight: FontWeight.w700)),
                ),
              ),
              AppleRow(
                leading: IconTile(Icons.photo_camera_rounded, Neon.accentA),
                title: 'Take a photo',
                trailing: const SizedBox.shrink(),
                onTap: () => Navigator.pop(c, ImageSource.camera),
              ),
              AppleRow(
                leading: IconTile(Icons.photo_library_rounded, Neon.accentC),
                title: 'Choose from gallery',
                trailing: const SizedBox.shrink(),
                onTap: () => Navigator.pop(c, ImageSource.gallery),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );

  Future<void> _photoActions(StudioPhoto p) async {
    final action = await showAppSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!p.isDefault)
              AppleRow(
                leading: Icon(Icons.check_circle_outline_rounded,
                    color: Neon.textHi),
                title: 'Use this one for my looks',
                trailing: const SizedBox.shrink(),
                onTap: () => Navigator.pop(c, 'default'),
              ),
            AppleRow(
              leading: Icon(Icons.delete_outline_rounded, color: Neon.error),
              title: 'Delete',
              titleColor: Neon.errorInk,
              trailing: const SizedBox.shrink(),
              onTap: () => Navigator.pop(c, 'delete'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (action == null) return;
    setState(() => _busy = true);
    try {
      if (action == 'default') {
        await StudioService.makeDefault(p.id);
      } else {
        await StudioService.deletePhoto(p.id);
      }
      await _load(silent: true);
    } catch (e) {
      _toast(e is StudioException && e.message.isNotEmpty
          ? e.message
          : "Couldn't reach the studio — try again.");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /* ---------------------------------------------------------------- */

  Future<void> _openRecipe(StudioRecipe r) async {
    final s = _state;
    if (s == null) return;
    if (r.needsModel && s.myPhotos.isEmpty) {
      _toast('Add a photo of yourself first — every look uses it.');
      await _addMyPhoto();
      if (!mounted || (_state?.myPhotos.isEmpty ?? true)) return;
    }
    final made = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => StudioLookScreen(recipe: r, state: _state!),
    ));
    if (made == true) _load(silent: true);
  }

  void _openLooks(int index) {
    final s = _state;
    if (s == null || s.looks.isEmpty) return;
    final docs = s.looks
        .map((l) => UserDocument(
              id: l.documentId,
              filename: 'look-${l.id}.jpg',
              mime: 'image/jpeg',
              title: l.prompt.isEmpty ? 'Style Studio' : l.prompt,
              category: 'other',
              docDate: '',
              summary: 'AI-generated from your own photo.',
              note: l.prompt,
              createdAt: l.createdAt,
            ))
        .toList(growable: false);
    Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => DocumentGalleryScreen(
        documents: docs,
        initialIndex: index,
        onDelete: (d) async {
          final look = s.looks.firstWhere((l) => l.documentId == d.id,
              orElse: () => s.looks.first);
          try {
            await StudioService.deleteLook(look.id);
            _load(silent: true);
            return true;
          } catch (_) {
            return false;
          }
        },
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    // Under Home's sky, with the app's detail bar (2026-09-30): Hub's
    // "Style Studio" now flies into this title as it does for every
    // other page.
    return NeonScaffold(
      appBar: appleAppBar(context, 'Style Studio', actions: [
          if (_state?.consented == true)
            IconButton(
              tooltip: 'Privacy',
              icon: const Icon(Icons.privacy_tip_outlined, size: 21),
              onPressed: _busy ? null : _withdraw,
            ),
      ]),
      body: _loading
          ? const NeonLoader.page(semanticLabel: 'Loading Style Studio')
          : _error.isNotEmpty
              ? _errorView()
              // Silent: the pull-to-refresh control draws its own spinner,
              // so blanking the list underneath it would show two at once
              // and throw away the user's scroll position.
              : RefreshIndicator(
                  onRefresh: () => _load(silent: true), child: StateSwitch.of(_body())),
    );
  }

  // The server's own reason, when it gave one, is the next step to read.
  Widget _errorView() => NeonErrorState(
        message: "Couldn't load Style Studio",
        hint: _error == _offline ? null : _error,
        onRetry: _load,
      );

  static const _offline = "Couldn't load Style Studio. Check your connection.";

  Widget _body() {
    final s = _state!;
    if (!s.consented) return _consentView();

    final groups = <String, List<StudioRecipe>>{};
    // "Restore an old photo" lived on the photo-card screen, removed
    // with it (owner, 2026-10-02).
    for (final r in s.recipes.where((r) => r.id != 'restore')) {
      groups.putIfAbsent(r.group, () => []).add(r);
    }

    return ListView(
      padding: EdgeInsets.fromLTRB(
          16, 4, 16, 40 + MediaQuery.paddingOf(context).bottom),
      children: [
        if (!s.anyProviderReady) _notConfiguredBanner(),
        _myPhotos(s),
        const SizedBox(height: 22),
        for (final entry in groups.entries) ...[
          _groupHeader(entry.key),
          _group(entry.value),
          const SizedBox(height: 22),
        ],
        if (s.looks.isNotEmpty) ...[
          _groupHeader('Your looks'),
          _looksGrid(s),
          const SizedBox(height: 18),
        ],
        _footer(s),
      ],
    );
  }

  /* ---------------------------------------------------------------- */

  Widget _consentView() => ListView(
        padding: EdgeInsets.fromLTRB(
            20, 8, 20, 40 + MediaQuery.paddingOf(context).bottom),
        children: [
          const SizedBox(height: 10),
          const Align(
            alignment: Alignment.centerLeft,
            child: BrandMark(size: 58),
          ),
          const SizedBox(height: 18),
          Text('See yourself in it first',
              style: GoogleFonts.spaceGrotesk(
                  fontSize: 25,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.5,
                  color: Neon.textHi)),
          const SizedBox(height: 12),
          Text(
            'Style Studio puts a new outfit, a different haircut or a '
            'professional backdrop onto a photo of you — so you can look '
            'before you buy, book or print.',
            style: TextStyle(color: Neon.textLo, fontSize: 15, height: 1.45),
          ),
          const SizedBox(height: 24),
          // What they agree to, lit as the page's one card.
          GlowCard(
            halo: 0.5,
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Before you start',
                    style: TextStyle(
                        color: Neon.textHi,
                        fontWeight: FontWeight.w700,
                        fontSize: 15)),
                const SizedBox(height: 12),
                _point(Icons.face_rounded,
                    'Your photo is stored on your own account and used only to make the looks you ask for.'),
                _point(Icons.person_outline_rounded,
                    'Use photos of yourself. Do not upload a photo of someone else.'),
                _point(Icons.auto_fix_high_rounded,
                    'Every result is AI-generated and labelled as such in your files.'),
                _point(Icons.delete_outline_rounded,
                    'You can remove your photos any time — the privacy button in the corner deletes them.'),
              ],
            ),
          ),
          const SizedBox(height: 26),
          // The one lit action (it was a flat white slab).
          GlowCta(
            label: 'I understand — continue',
            busy: _busy,
            onPressed: _accept,
          ),
        ],
      );

  Widget _point(IconData i, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 11),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(i, size: 17, color: Neon.violet),
            const SizedBox(width: 11),
            Expanded(
              child: Text(text,
                  style: TextStyle(
                      color: Neon.textLo, fontSize: 14, height: 1.4)),
            ),
          ],
        ),
      );

  // An amber rim, unlit: a state to notice, not the page's news.
  Widget _notConfiguredBanner() => Padding(
        padding: const EdgeInsets.only(bottom: 18),
        child: GlowCard(
        tone: NeonTone.warning,
        halo: 0,
        rimWidth: 1.2,
        radius: Neon.rSm,
        padding: const EdgeInsets.all(12.8),
        child: Row(
          children: [
            Icon(Icons.build_circle_outlined, size: 19, color: Neon.warning),
            const SizedBox(width: 11),
            Expanded(
              child: Text(
                'New looks are not available right now. '
                'Everything else here works.',
                style: TextStyle(color: Neon.textLo, fontSize: 13, height: 1.35),
              ),
            ),
          ],
        ),
        ),
      );

  Widget _myPhotos(StudioState s) {
    final mine = s.myPhotos;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _groupHeader(mine.isEmpty ? 'Start here' : 'Your photo'),
        SizedBox(
          height: 108,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              _addTile(first: mine.isEmpty),
              for (final p in mine) _photoTile(p),
            ],
          ),
        ),
        if (mine.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 10, left: 2),
            child: Text(
              'One clear, well-lit photo — face and shoulders visible. Every '
              'look uses it, so you only do this once.',
              style: TextStyle(color: Neon.textLo, fontSize: 13, height: 1.4),
            ),
          ),
      ],
    );
  }

  // Tappable (2026-09-30): the dip, the tick, and a name to hear.
  // 2026-09-30 visual QA: with no photo yet this is the page's one first
  // step ("Start here"), so it wears the lit cyan rim; it was a plain grey
  // box that read as disabled.
  Widget _addTile({bool first = false}) => Padding(
        padding: const EdgeInsets.only(right: 10),
        child: Tappable(
          onTap: _busy ? null : _addMyPhoto,
          semanticLabel: 'Add a photo of you',
          child: Container(
            width: 82,
            decoration: BoxDecoration(
              color: first ? NeonTone.tip.fill : Neon.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: first ? Neon.cyan : Neon.lineBright,
                  width: first ? 1.6 : 1),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.add_a_photo_outlined,
                    size: 22, color: first ? NeonTone.tip.ink : Neon.textLo),
                const SizedBox(height: 7),
                Text('Add',
                    style: TextStyle(
                        color: first ? NeonTone.tip.ink : Neon.textLo,
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
      );

  // THE CHOSEN PHOTO IS LIT (2026-09-30): the one every look uses
  // wears a cyan rim and its glow; the tick sits in the same light.
  Widget _photoTile(StudioPhoto p) => Padding(
        padding: const EdgeInsets.only(right: 10),
        child: Tappable(
          onTap: _busy ? null : () => _photoActions(p),
          semanticLabel: p.isDefault
              ? 'Your photo, used for your looks'
              : 'Your photo',
          tapHint: 'show options',
          child: Stack(
            children: [
              // The glow under the photo, the rim over its edge.
              Container(
                width: 82,
                height: 108,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: p.isDefault
                      ? Neon.halo(Neon.cyan, strength: 0.8)
                      : null,
                ),
              ),
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  width: 82,
                  height: 108,
                  color: Neon.surfaceHigh,
                  foregroundDecoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: p.isDefault ? Neon.cyan : Neon.line,
                        width: p.isDefault ? 2 : 1),
                  ),
                  child: Image.network(
                    p.imageUrl,
                    headers: ApiService.imageHeaders,
                    fit: BoxFit.cover,
                    // DECODE TO THE TILE, not to the source. These are
                    // multi-megapixel phone photos drawn into an 82 px
                    // thumbnail; without a cap Flutter decodes every one at
                    // full resolution and holds the whole bitmap in memory.
                    cacheWidth: 260,
                    filterQuality: FilterQuality.medium,
                    errorBuilder: (_, __, ___) =>
                        Icon(Icons.person_rounded, color: Neon.textDim),
                  ),
                ),
              ),
              if (p.isDefault)
                Positioned(
                  right: 5,
                  top: 5,
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                        color: Neon.cyan, shape: BoxShape.circle),
                    child: Icon(Icons.check_rounded,
                        size: 12, color: Neon.glyphOn(Neon.cyan)),
                  ),
                ),
            ],
          ),
        ),
      );

  // The app's one section label (2026-09-30; textDim was under 4.5:1
  // on the sky).
  Widget _groupHeader(String t) => GroupLabel(t);

  static const _icons = <String, IconData>{
    'outfit': Icons.dry_cleaning_rounded,
    'hair': Icons.content_cut_rounded,
    'beard': Icons.face_retouching_natural_rounded,
    'eyewear': Icons.visibility_rounded,
    'jewellery': Icons.diamond_rounded,
    'headshot': Icons.badge_rounded,
    'id': Icons.credit_card_rounded,
    'restore': Icons.auto_fix_high_rounded,
    'backdrop': Icons.wallpaper_rounded,
    'occasion': Icons.celebration_rounded,
  };

  // The app's own accent family, not literal iOS system colours: they
  // follow the theme and the chosen accent like every other tile.
  static Map<String, Color> get _colors => <String, Color>{
        'outfit': AppleColors.blue,
        'hair': AppleColors.purple,
        'beard': AppleColors.indigo,
        'eyewear': AppleColors.teal,
        'jewellery': AppleColors.gray,
        'headshot': AppleColors.green,
        'id': AppleColors.orange,
        'restore': AppleColors.teal,
        'backdrop': AppleColors.green,
        'occasion': AppleColors.gray,
      };

  // The app's lit group (GroupedCard), as on every other list.
  Widget _group(List<StudioRecipe> rows) => GroupedCard(
        dividerInset: 58,
        children: [for (final r in rows) _recipeRow(r)],
      );

  // The row dips like every AppleRow; its tile is the shared lit one.
  Widget _recipeRow(StudioRecipe r) => PressScale(
        scale: 0.985,
        child: InkWell(
        onTap: _busy
            ? null
            : () {
                HapticFeedback.selectionClick();
                _openRecipe(r);
              },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 11, 12, 11),
          child: Row(
            children: [
              IconTile(_icons[r.icon] ?? Icons.auto_awesome_rounded,
                  _colors[r.icon] ?? Neon.violet,
                  size: 30),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(r.title,
                        style: TextStyle(
                            color: Neon.textHi,
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                            letterSpacing: -0.2)),
                    const SizedBox(height: 1),
                    Text(r.blurb,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Neon.textLo, fontSize: 13)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: Neon.textDim, size: 20),
            ],
          ),
        ),
        ),
      );

  Widget _looksGrid(StudioState s) => GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: 0.78,
        ),
        itemCount: s.looks.length,
        itemBuilder: (_, i) {
          final l = s.looks[i];
          // Each made look framed in the purple of something to
          // discover (2026-09-30): a rim, no glow — a grid where every
          // tile glowed would have no focus.
          return GlowCard(
            tone: NeonTone.discovery,
            halo: 0,
            rimWidth: 1.2,
            radius: 11.2,
            onTap: () => _openLooks(i),
            semanticLabel: 'Look ${i + 1}',
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Container(
                color: Neon.surfaceHigh,
                child: Image.network(
                  l.imageUrl,
                  headers: ApiService.imageHeaders,
                  fit: BoxFit.cover,
                  // A generated look is up to 2K. A three-column grid of
                  // them decoded at source size is what makes this screen
                  // stutter on a mid-range phone, and can push it to an
                  // out-of-memory kill once the grid is a few rows deep.
                  cacheWidth: 360,
                  filterQuality: FilterQuality.medium,
                  errorBuilder: (_, __, ___) =>
                      Icon(Icons.broken_image_outlined, color: Neon.textDim),
                ),
              ),
            ),
          );
        },
      );

  Widget _footer(StudioState s) => Padding(
        padding: const EdgeInsets.only(top: 6, left: 4, right: 4),
        child: Text(
          '${s.remaining} of ${s.limit} looks left today · '
          'Results are AI-generated from your own photo and saved to your files.',
          style: TextStyle(
              color: Neon.textLo, fontSize: NeonType.caption, height: 1.4),
        ),
      );
}
