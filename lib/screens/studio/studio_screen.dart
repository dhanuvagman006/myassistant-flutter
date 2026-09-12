import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';

import '../../design/neon_tokens.dart';
import '../../features/assistant/widgets/action_cards.dart'
    show DocumentGalleryScreen;
import '../../models/user_document.dart';
import '../../services/api_service.dart';
import '../../services/studio_service.dart';
import 'studio_look_screen.dart';

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
            : "Couldn't load Style Studio. Check your connection.";
      });
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
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
      _toast('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _withdraw() async {
    final yes = await showDialog<bool>(
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
              child: Text('Remove', style: TextStyle(color: Neon.error))),
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
      _toast('$e');
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

  Future<ImageSource?> _pickSource(String title) => showModalBottomSheet<ImageSource>(
        context: context,
        backgroundColor: Neon.surface,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
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
              ListTile(
                leading: Icon(Icons.photo_camera_rounded, color: Neon.textHi),
                title: const Text('Take a photo'),
                onTap: () => Navigator.pop(c, ImageSource.camera),
              ),
              ListTile(
                leading: Icon(Icons.photo_library_rounded, color: Neon.textHi),
                title: const Text('Choose from gallery'),
                onTap: () => Navigator.pop(c, ImageSource.gallery),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );

  Future<void> _photoActions(StudioPhoto p) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Neon.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!p.isDefault)
              ListTile(
                leading: Icon(Icons.check_circle_outline_rounded,
                    color: Neon.textHi),
                title: const Text('Use this one for my looks'),
                onTap: () => Navigator.pop(c, 'default'),
              ),
            ListTile(
              leading: Icon(Icons.delete_outline_rounded, color: Neon.error),
              title: Text('Delete', style: TextStyle(color: Neon.error)),
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
      _toast('$e');
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
    return Scaffold(
      backgroundColor: Neon.bg,
      appBar: AppBar(
        backgroundColor: Neon.bg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Neon.textHi,
        title: Text('Style Studio',
            style: GoogleFonts.spaceGrotesk(
                fontSize: 21, fontWeight: FontWeight.w700, letterSpacing: -0.4)),
        actions: [
          if (_state?.consented == true)
            IconButton(
              tooltip: 'Privacy',
              icon: const Icon(Icons.privacy_tip_outlined, size: 21),
              onPressed: _busy ? null : _withdraw,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error.isNotEmpty
              ? _errorView()
              // Silent: the pull-to-refresh control draws its own spinner,
              // so blanking the list underneath it would show two at once
              // and throw away the user's scroll position.
              : RefreshIndicator(
                  onRefresh: () => _load(silent: true), child: _body()),
    );
  }

  Widget _errorView() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.cloud_off_rounded, size: 42, color: Neon.textDim),
              const SizedBox(height: 14),
              Text(_error,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Neon.textLo, fontSize: 14.5)),
              const SizedBox(height: 18),
              FilledButton(onPressed: _load, child: const Text('Try again')),
            ],
          ),
        ),
      );

  Widget _body() {
    final s = _state!;
    if (!s.consented) return _consentView();

    final groups = <String, List<StudioRecipe>>{};
    for (final r in s.recipes) {
      groups.putIfAbsent(r.group, () => []).add(r);
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
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
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: [
          const SizedBox(height: 10),
          Icon(Icons.auto_awesome_rounded, size: 46, color: Neon.violet),
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
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Neon.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Neon.line),
            ),
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
          FilledButton(
            onPressed: _busy ? null : _accept,
            style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
                backgroundColor: Neon.textHi,
                foregroundColor: Neon.onInk),
            child: _busy
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('I understand — continue',
                    style: TextStyle(fontWeight: FontWeight.w600)),
          ),
        ],
      );

  Widget _point(IconData i, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 11),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(i, size: 17, color: Neon.textDim),
            const SizedBox(width: 11),
            Expanded(
              child: Text(text,
                  style: TextStyle(
                      color: Neon.textLo, fontSize: 13.5, height: 1.4)),
            ),
          ],
        ),
      );

  Widget _notConfiguredBanner() => Container(
        margin: const EdgeInsets.only(bottom: 18),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Neon.warning.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Neon.warning.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            Icon(Icons.build_circle_outlined, size: 19, color: Neon.warning),
            const SizedBox(width: 11),
            Expanded(
              child: Text(
                'Image editing is not switched on for this server yet, so '
                'looks will not render. Everything else here works.',
                style: TextStyle(color: Neon.textLo, fontSize: 12.5, height: 1.35),
              ),
            ),
          ],
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
              _addTile(),
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
              style: TextStyle(color: Neon.textLo, fontSize: 12.5, height: 1.4),
            ),
          ),
      ],
    );
  }

  Widget _addTile() => Padding(
        padding: const EdgeInsets.only(right: 10),
        child: InkWell(
          onTap: _busy ? null : _addMyPhoto,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            width: 82,
            decoration: BoxDecoration(
              color: Neon.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Neon.lineBright),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.add_a_photo_outlined, size: 22, color: Neon.textLo),
                const SizedBox(height: 7),
                Text('Add',
                    style: TextStyle(
                        color: Neon.textLo,
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
      );

  Widget _photoTile(StudioPhoto p) => Padding(
        padding: const EdgeInsets.only(right: 10),
        child: GestureDetector(
          onTap: _busy ? null : () => _photoActions(p),
          child: Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  width: 82,
                  height: 108,
                  color: Neon.surfaceHigh,
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
                        color: Neon.textHi, shape: BoxShape.circle),
                    child: Icon(Icons.check_rounded,
                        size: 12, color: Neon.onInk),
                  ),
                ),
            ],
          ),
        ),
      );

  Widget _groupHeader(String t) => Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 9, top: 2),
        child: Text(t.toUpperCase(),
            style: TextStyle(
                color: Neon.textDim,
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5)),
      );

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

  static const _colors = <String, Color>{
    'outfit': Color(0xFF007AFF),
    'hair': Color(0xFFAF52DE),
    'beard': Color(0xFF5856D6),
    'eyewear': Color(0xFF0E7490),
    'jewellery': Color(0xFFBE185D),
    'headshot': Color(0xFF34C759),
    'id': Color(0xFFFF9500),
    'restore': Color(0xFF8E8E93),
    'backdrop': Color(0xFF4D7C0F),
    'occasion': Color(0xFFFF375F),
  };

  Widget _group(List<StudioRecipe> rows) => Material(
        color: Neon.surface,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0)
                Padding(
                  padding: const EdgeInsets.only(left: 60),
                  child: Divider(
                      height: 1, thickness: 0.5, color: Neon.line),
                ),
              _recipeRow(rows[i]),
            ],
          ],
        ),
      );

  Widget _recipeRow(StudioRecipe r) => InkWell(
        onTap: _busy ? null : () => _openRecipe(r),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 11, 12, 11),
          child: Row(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: _colors[r.icon] ?? Neon.violet,
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Icon(_icons[r.icon] ?? Icons.auto_awesome_rounded,
                    color: Colors.white, size: 18),
              ),
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
                        style: TextStyle(color: Neon.textLo, fontSize: 12.5)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: Neon.textDim, size: 20),
            ],
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
          return GestureDetector(
            onTap: () {
              HapticFeedback.selectionClick();
              _openLooks(i);
            },
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
          style: TextStyle(color: Neon.textDim, fontSize: 11.5, height: 1.4),
        ),
      );
}
