import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../design/apple_kit.dart';
import '../../design/neon_tokens.dart';
import '../../design/neon_widgets.dart';
import '../../features/assistant/widgets/action_cards.dart'
    show DocumentGalleryScreen;
import '../../services/api_service.dart';
import '../../services/studio_service.dart';
import '../../services/app_feedback.dart';
import '../../design/motion.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  ONE LOOK — pick the details, make it, see it full screen.
///
///  The form is built from the recipe the SERVER described, so a look added
///  or changed on the server needs no app release. Nothing about outfits or
///  hairstyles is hardcoded here.
/// ─────────────────────────────────────────────────────────────────────────
class StudioLookScreen extends StatefulWidget {
  final StudioRecipe recipe;
  final StudioState state;

  const StudioLookScreen({super.key, required this.recipe, required this.state});

  @override
  State<StudioLookScreen> createState() => _StudioLookScreenState();
}

class _StudioLookScreenState extends State<StudioLookScreen> {
  final _controllers = <String, TextEditingController>{};
  final _choices = <String, String>{};
  String? _preset;

  StudioPhoto? _basePhoto;

  /// A garment photographed for this one look — not saved to the wardrobe
  /// unless the user asks.
  List<int>? _garmentBytes;
  String _garmentMime = 'image/jpeg';
  int? _garmentId;

  bool _running = false;
  int _elapsed = 0;
  Timer? _tick;
  String _error = '';
  StudioResult? _result;

  /// True once a look has been made, so the parent refreshes on pop.
  bool _madeSomething = false;

  StudioRecipe get r => widget.recipe;

  @override
  void initState() {
    super.initState();
    _basePhoto = widget.state.defaultPhoto;
    for (final p in r.params) {
      if (p.type == 'text') {
        _controllers[p.key] = TextEditingController();
      } else if (p.options.isNotEmpty) {
        // Deliberately NOT pre-selected: a silently pre-chosen "Business
        // suit" would put the user in a suit they never asked for. The
        // server treats an absent value as "you decide".
        _choices[p.key] = '';
      }
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _toast(String m) {
    if (!mounted) return;
    AppFeedback.show(m, context: context);
  }

  /* ---------------------------------------------------------------- */

  Map<String, String> _params() {
    final out = <String, String>{};
    if (_preset != null) out['preset'] = _preset!;
    for (final e in _controllers.entries) {
      final v = e.value.text.trim();
      if (v.isNotEmpty) out[e.key] = v;
    }
    for (final e in _choices.entries) {
      if (e.value.isNotEmpty) out[e.key] = e.value;
    }
    return out;
  }

  /// The one thing the user must supply for some recipes — an ID photo
  /// without a document type is a photo of the wrong size.
  String? _missingRequired() {
    for (final p in r.params) {
      if (!p.required) continue;
      final has = p.type == 'text'
          ? (_controllers[p.key]?.text.trim().isNotEmpty ?? false)
          : (_choices[p.key] ?? '').isNotEmpty;
      if (!has) return p.label;
    }
    return null;
  }

  Future<void> _pickGarment() async {
    final src = await showAppSheet<ImageSource>(
      context: context,
      // The theme's sheet (2026-09-30): its lit edge and radius.
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppleRow(
              leading: IconTile(Icons.photo_camera_rounded, Neon.accentA),
              title: 'Photograph the item',
              subtitle: 'Lay it flat, or shoot it on the hanger',
              trailing: const SizedBox.shrink(),
              onTap: () => Navigator.pop(c, ImageSource.camera),
            ),
            AppleRow(
              leading: IconTile(Icons.photo_library_rounded, Neon.accentC),
              title: 'Choose a photo',
              subtitle: 'A screenshot from a shopping app works',
              trailing: const SizedBox.shrink(),
              onTap: () => Navigator.pop(c, ImageSource.gallery),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (src == null) return;
    final shot = await ImagePicker()
        .pickImage(source: src, imageQuality: 92, maxWidth: 2000, maxHeight: 2000);
    if (shot == null) return;
    final bytes = await shot.readAsBytes();
    if (!mounted) return;
    setState(() {
      _garmentBytes = bytes;
      _garmentMime = shot.mimeType ?? 'image/jpeg';
      _garmentId = null;
    });
  }

  Future<void> _pickFromWardrobe() async {
    final w = widget.state.wardrobe;
    if (w.isEmpty) {
      _toast('Nothing in your wardrobe yet — photograph an item instead.');
      return;
    }
    final chosen = await showAppSheet<StudioPhoto>(
      context: context,
      // The theme's sheet (2026-09-30): its lit edge and radius.
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Your wardrobe',
                  style: TextStyle(
                      color: Neon.textHi,
                      fontSize: 17,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 14),
              SizedBox(
                height: 120,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final p in w)
                      Padding(
                        padding: const EdgeInsets.only(right: 10),
                        child: Tappable(
                          onTap: () => Navigator.pop(c, p),
                          semanticLabel: 'Wardrobe item',
                          tapHint: 'choose',
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: Container(
                              width: 92,
                              color: Neon.surfaceHigh,
                              child: Image.network(p.imageUrl,
                                  headers: ApiService.imageHeaders,
                                  fit: BoxFit.cover,
                                  cacheWidth: 280,
                                  filterQuality: FilterQuality.medium),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    setState(() {
      _garmentId = chosen.id;
      _garmentBytes = null;
    });
  }

  /* ---------------------------------------------------------------- */

  Future<void> _run() async {
    final missing = _missingRequired();
    if (missing != null) {
      _toast('Choose $missing first.');
      return;
    }
    HapticFeedback.mediumImpact();
    setState(() {
      _running = true;
      _error = '';
      _result = null;
      _elapsed = 0;
    });
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsed++);
    });
    try {
      final out = await StudioService.run(
        recipe: r.id,
        params: _params(),
        photoId: _basePhoto?.id,
        garmentId: _garmentId,
        garmentBytes: _garmentBytes,
        garmentMime: _garmentMime,
      );
      if (!mounted) return;
      _madeSomething = true;
      setState(() => _result = out);
      HapticFeedback.lightImpact();
      _showFullScreen(out);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e is StudioException
          ? (e.message.isNotEmpty ? e.message : 'That did not come out.')
          : 'That did not come out. Check your connection and try again.');
    } finally {
      _tick?.cancel();
      if (mounted) setState(() => _running = false);
    }
  }

  void _showFullScreen(StudioResult out) {
    Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => DocumentGalleryScreen(documents: [out.document]),
    ));
  }

  /* ---------------------------------------------------------------- */

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_running,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _running) {
          _toast('Still working — it will be in your files either way.');
        }
      },
      // Under Home's sky, with the app's detail bar (2026-09-30).
      child: NeonScaffold(
        appBar: appleAppBar(
          context,
          r.title,
          leading: IconButton(
            tooltip: 'Back',
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: () => Navigator.pop(context, _madeSomething),
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 40),
          children: [
            if (r.needsModel) _baseRow(),
            if (r.presets.isNotEmpty) ...[
              const SizedBox(height: 20),
              _label('Pick one, or describe it yourself'),
              const SizedBox(height: 10),
              _presetChips(),
            ],
            if (r.acceptsGarment) ...[
              const SizedBox(height: 22),
              _label(r.id == 'outfit'
                  ? 'Have a photo of the actual item?'
                  : 'Have a photo of the actual piece?'),
              const SizedBox(height: 4),
              Text(
                'A photo of the real thing keeps its exact colour, print and '
                'texture. Without one it is made from your description.',
                style: TextStyle(color: Neon.textLo, fontSize: 13, height: 1.4),
              ),
              const SizedBox(height: 12),
              _garmentRow(),
            ],
            for (final p in r.params) ...[
              const SizedBox(height: 20),
              _field(p),
            ],
            const SizedBox(height: 28),
            if (_error.isNotEmpty) _errorBox(),
            _runButton(),
            if (_result != null) ...[
              const SizedBox(height: 22),
              _resultCard(_result!),
            ],
            const SizedBox(height: 18),
            Text(
              'AI-generated from your own photo. Saved to your files and '
              'labelled as AI-generated.',
              style: TextStyle(
                  color: Neon.textLo, fontSize: NeonType.caption, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }

  Widget _label(String t) => Text(t,
      style: TextStyle(
          color: Neon.textHi, fontSize: 15, fontWeight: FontWeight.w600));

  Widget _baseRow() {
    final mine = widget.state.myPhotos;
    return Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(9),
          child: Container(
            width: 46,
            height: 58,
            color: Neon.surfaceHigh,
            child: _basePhoto == null
                ? Icon(Icons.person_rounded, color: Neon.textDim, size: 20)
                : Image.network(_basePhoto!.imageUrl,
                    headers: ApiService.imageHeaders,
                    fit: BoxFit.cover,
                    cacheWidth: 180,
                    filterQuality: FilterQuality.medium),
          ),
        ),
        const SizedBox(width: 13),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Using your photo',
                  style: TextStyle(
                      color: Neon.textHi,
                      fontSize: 15,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(
                _basePhoto == null
                    ? 'No photo saved'
                    : (_basePhoto!.label.isEmpty
                        ? 'Your saved photo'
                        : _basePhoto!.label),
                style: TextStyle(color: Neon.textLo, fontSize: 13),
              ),
            ],
          ),
        ),
        if (mine.length > 1)
          TextButton(
            onPressed: _running ? null : _switchBase,
            child: const Text('Change'),
          ),
      ],
    );
  }

  Future<void> _switchBase() async {
    final chosen = await showAppSheet<StudioPhoto>(
      context: context,
      // The theme's sheet (2026-09-30): its lit edge and radius.
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            height: 130,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final p in widget.state.myPhotos)
                  Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: Tappable(
                      onTap: () => Navigator.pop(c, p),
                      semanticLabel: 'Your photo',
                      tapHint: 'choose',
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Container(
                          width: 92,
                          color: Neon.surfaceHigh,
                          child: Image.network(p.imageUrl,
                              headers: ApiService.imageHeaders,
                              fit: BoxFit.cover,
                              cacheWidth: 280,
                              filterQuality: FilterQuality.medium),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    if (chosen != null && mounted) setState(() => _basePhoto = chosen);
  }

  Widget _presetChips() => Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final p in r.presets)
            ChoiceChip(
              label: Text(p.label),
              selected: _preset == p.id,
              onSelected: _running
                  ? null
                  : (on) => setState(() => _preset = on ? p.id : null),
              // THE CHOSEN LOOK IS LIT (2026-09-30): the theme's chip —
              // a violet ground and a lit rim for the one picked, where a
              // white slab stood.
              labelStyle: TextStyle(
                color: _preset == p.id ? Neon.textHi : Neon.textLo,
                fontWeight:
                    _preset == p.id ? FontWeight.w700 : FontWeight.w500,
              ),
              showCheckmark: false,
            ),
        ],
      );

  Widget _garmentRow() {
    final attached = _garmentBytes != null || _garmentId != null;
    return Row(
      children: [
        if (attached)
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(9),
              child: Container(
                width: 52,
                height: 52,
                color: Neon.surfaceHigh,
                // Decoded small, like the network branch below: the picked
                // photo (up to 2000 px, ~16 MB decoded) was decoded at full
                // size for a 52 dp thumbnail.
                child: _garmentBytes != null
                    ? Image.memory(_bytes(_garmentBytes!),
                        fit: BoxFit.cover,
                        cacheWidth: 160,
                        filterQuality: FilterQuality.medium)
                    : Image.network(
                        ApiService.documentFileUrl(widget.state.wardrobe
                            .firstWhere((p) => p.id == _garmentId,
                                orElse: () => widget.state.wardrobe.first)
                            .documentId),
                        headers: ApiService.imageHeaders,
                        fit: BoxFit.cover,
                        cacheWidth: 160,
                        filterQuality: FilterQuality.medium),
              ),
            ),
          ),
        Expanded(
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _running ? null : _pickGarment,
                icon: const Icon(Icons.add_a_photo_outlined, size: 17),
                label: Text(attached ? 'Replace' : 'Add a photo'),
              ),
              if (widget.state.wardrobe.isNotEmpty)
                OutlinedButton.icon(
                  onPressed: _running ? null : _pickFromWardrobe,
                  icon: const Icon(Icons.inventory_2_outlined, size: 17),
                  label: const Text('Wardrobe'),
                ),
              if (attached)
                TextButton(
                  onPressed: _running
                      ? null
                      : () => setState(() {
                            _garmentBytes = null;
                            _garmentId = null;
                          }),
                  child: const Text('Remove'),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _field(StudioParam p) {
    if (p.type == 'choice' && p.options.isNotEmpty) {
      final value = (_choices[p.key] ?? '').isEmpty ? null : _choices[p.key];
      return DropdownButtonFormField<String>(
        initialValue: value,
        isExpanded: true,
        // The theme's field and menu (2026-09-30).
        decoration: InputDecoration(
          labelText: p.label + (p.required ? ' *' : ''),
        ),
        hint: Text(p.required ? 'Choose one' : 'Let the assistant decide',
            style: TextStyle(color: Neon.textDim, fontSize: 14)),
        items: [
          for (final o in p.options)
            DropdownMenuItem(value: o, child: Text(o, overflow: TextOverflow.ellipsis)),
        ],
        onChanged: _running
            ? null
            : (v) => setState(() => _choices[p.key] = v ?? ''),
      );
    }
    return TextField(
      controller: _controllers[p.key],
      enabled: !_running,
      maxLines: p.key == 'notes' ? 3 : 2,
      minLines: 1,
      textCapitalization: TextCapitalization.sentences,
      style: TextStyle(color: Neon.textHi, fontSize: 15),
      decoration: InputDecoration(
        labelText: p.label + (p.required ? ' *' : ''),
        hintText: p.hint.isEmpty ? null : 'e.g. ${p.hint}',
      ),
    );
  }

  // Could-not, in the danger tone's rim (2026-09-30).
  Widget _errorBox() => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: GlowCard(
        tone: NeonTone.danger,
        halo: 0.35,
        rimWidth: 1.4,
        radius: Neon.rSm,
        padding: const EdgeInsets.all(11.6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline_rounded, size: 18, color: Neon.error),
            const SizedBox(width: 10),
            Expanded(
              child: Text(_error,
                  style: TextStyle(
                      color: Neon.textLo, fontSize: 13, height: 1.4)),
            ),
          ],
        ),
        ),
      );

  // THE ONE LIT ACTION (2026-09-30): the accent fill with the brand's
  // halo, and still lit while it works (it was a flat white slab, and a
  // grey one while running).
  Widget _runButton() => DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          boxShadow: Neon.halo(Neon.violet),
        ),
        child: FilledButton(
        onPressed: _running ? null : _run,
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          disabledBackgroundColor: _running ? Neon.accentFill : null,
          disabledForegroundColor: _running ? Neon.onAccent : null,
        ),
        child: _running
            ? Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const NeonLoader.inline(size: 17, semanticLabel: 'Working'),
                  const SizedBox(width: 12),
                  Text(_progressWord(),
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ],
              )
            : Text(_result == null ? 'Make it' : 'Make another',
                style: const TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 16)),
        ),
      );

  /// Honest progress. There is no percentage to report, so the copy tracks
  /// elapsed time instead of inventing one — and it stops promising speed
  /// once the render is genuinely taking a while.
  String _progressWord() {
    if (_elapsed < 6) return 'Setting it up…';
    if (_elapsed < 16) return 'Making it… ${_elapsed}s';
    if (_elapsed < 40) return 'Getting the details right… ${_elapsed}s';
    return 'Still working — ${_elapsed}s';
  }

  // THE RESULT IS THE LIT CARD (2026-09-30): made and saved, in the
  // green of done-and-well.
  Widget _resultCard(StudioResult out) => GlowCard(
        tone: NeonTone.success,
        halo: 0.7,
        padding: const EdgeInsets.all(11),
        child: Row(
          children: [
            Tappable(
              onTap: () => _showFullScreen(out),
              semanticLabel: 'Your new look',
              tapHint: 'view',
              child: ClipRRect(
                borderRadius: BorderRadius.circular(9),
                child: Container(
                  width: 58,
                  height: 74,
                  color: Neon.surfaceHigh,
                  child: Image.network(
                    ApiService.documentFileUrl(out.document.id),
                    headers: ApiService.imageHeaders,
                    fit: BoxFit.cover,
                    cacheWidth: 180,
                    filterQuality: FilterQuality.medium,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Saved to your files',
                      style: TextStyle(
                          color: Neon.textHi,
                          fontSize: 15,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 3),
                  Text(
                    out.specSize.isNotEmpty
                        ? out.specSize
                        : 'Open it from Hub, My documents',
                    style: TextStyle(
                        color: Neon.textLo, fontSize: NeonType.caption),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'View',
              icon: Icon(Icons.open_in_full_rounded,
                  size: 19, color: Neon.textLo),
              onPressed: () => _showFullScreen(out),
            ),
          ],
        ),
      );
}

/// The picker hands back a `List<int>`; Image.memory needs a `Uint8List`.
/// One tiny helper beats scattering casts through the build method.
Uint8List _bytes(List<int> b) => b is Uint8List ? b : Uint8List.fromList(b);
