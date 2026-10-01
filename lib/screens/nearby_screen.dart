import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/apple_kit.dart';
import '../design/dock_metrics.dart';
import '../design/neon_tokens.dart';
import '../design/neon_widgets.dart';
import '../services/api_service.dart';
import '../services/app_feedback.dart';
import '../services/location_service.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  NEARBY — people around who share what they do (2026-10-01, the owner:
///  "the user says he is a lawyer and he is in my locality; if I say
///  'find me the nearby lawyers' it should show them — any profession").
///
///  Two things on one tab: what YOU share (your profession and the switch
///  to be found), and a search of people nearby who switched it on. A
///  result is a name, a profession, an area and a distance — never an
///  exact location or a number; reaching them is a message through their
///  own assistant. The same list reaches the voice: "find nearby lawyers".
/// ─────────────────────────────────────────────────────────────────────────
class NearbyScreen extends StatefulWidget {
  const NearbyScreen({super.key});

  @override
  State<NearbyScreen> createState() => _NearbyScreenState();
}

class _NearbyScreenState extends State<NearbyScreen> {
  static const chips = [
    'Doctor',
    'Lawyer',
    'Electrician',
    'Plumber',
    'Teacher',
    'CA',
    'Mechanic',
    'Photographer',
    'Tailor',
    'Carpenter',
  ];

  final _query = TextEditingController();
  String _profession = '';
  String _area = '';
  bool _shared = false;
  bool _loadingMe = true;
  bool _searching = false;
  bool _needsLocation = false;
  String? _searched;
  List<Map<String, dynamic>> _people = const [];

  @override
  void initState() {
    super.initState();
    _loadMe();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _loadMe() async {
    final me = await ApiService.nearbyMe();
    if (!mounted) return;
    setState(() {
      _loadingMe = false;
      _profession = (me?['profession'] ?? '').toString();
      _area = (me?['area'] ?? '').toString();
      _shared = me?['shared'] == true;
    });
  }

  /// The phone's position, fresh enough to look around it.
  Future<bool> _located() async {
    if (ApiService.geoLat == null || ApiService.geoLng == null) {
      await LocationService.instance.refresh();
    }
    return ApiService.geoLat != null && ApiService.geoLng != null;
  }

  Future<void> _search(String q) async {
    final want = q.trim();
    if (want.isEmpty) return;
    HapticFeedback.selectionClick();
    setState(() {
      _searching = true;
      _searched = want;
      _needsLocation = false;
      _query.text = want;
    });
    final ok = await _located();
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _searching = false;
        _needsLocation = true;
        _people = const [];
      });
      return;
    }
    final people = await ApiService.nearbyProfessionals(want);
    if (!mounted) return;
    setState(() {
      _searching = false;
      _people = people;
    });
  }

  Future<void> _editProfession() async {
    final c = TextEditingController(text: _profession);
    final saved = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('What do you do?'),
        content: TextField(
          controller: c,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration:
              const InputDecoration(hintText: 'Lawyer, electrician, teacher…'),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(c.text),
              child: const Text('Save')),
        ],
      ),
    );
    if (saved == null) return;
    final me = await ApiService.setNearbyMe(profession: saved.trim());
    if (!mounted) return;
    setState(() {
      _profession = (me?['profession'] ?? saved.trim()).toString();
      _area = (me?['area'] ?? _area).toString();
    });
  }

  Future<void> _setShared(bool v) async {
    HapticFeedback.selectionClick();
    if (v && !await _located()) {
      if (!mounted) return;
      AppFeedback.show('Turn on location first so people nearby can find you.',
          context: context, tone: FeedbackTone.error);
      return;
    }
    final me = await ApiService.setNearbyMe(shared: v);
    if (!mounted) return;
    setState(() {
      _shared = me?['shared'] == true;
      _area = (me?['area'] ?? '').toString();
    });
  }

  Future<void> _message(Map<String, dynamic> p) async {
    final c = TextEditingController();
    final text = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Neon.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
            20, 18, 20, 20 + MediaQuery.of(ctx).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Message ${p['name']}',
                style: NeonType.manrope(NeonType.headline, FontWeight.w800)
                    .copyWith(color: Neon.textHi)),
            const SizedBox(height: 4),
            Text(
                'Their assistant reads it to them. They see your name and profession, not your number.',
                style: TextStyle(
                    color: Neon.textDim,
                    fontSize: NeonType.footnote,
                    height: 1.35)),
            const SizedBox(height: 14),
            TextField(
              controller: c,
              autofocus: true,
              maxLines: 3,
              minLines: 1,
              textCapitalization: TextCapitalization.sentences,
              decoration:
                  const InputDecoration(hintText: 'Hello, I need help with…'),
            ),
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: () => Navigator.of(ctx).pop(c.text),
                icon: const Icon(Icons.send_rounded, size: 18),
                label: const Text('Send'),
              ),
            ),
          ],
        ),
      ),
    );
    if (text == null || text.trim().isEmpty) return;
    final ok =
        await ApiService.nearbyContact((p['id'] as num).toInt(), text.trim());
    if (!mounted) return;
    AppFeedback.show(
        ok ? 'Sent through their assistant.' : "Couldn't send that just now.",
        context: context,
        tone: ok ? FeedbackTone.success : FeedbackTone.error);
  }

  @override
  Widget build(BuildContext context) {
    final pushed = ModalRoute.of(context)?.canPop ?? false;
    // A text field and chips need a Material ancestor; as a tab this
    // screen has none of its own (the shell's is above the pager).
    return Material(
      type: MaterialType.transparency,
      child: SafeArea(
        top: !pushed,
        bottom: false,
        child: ListView(
          padding: EdgeInsets.fromLTRB(
              16, pushed ? 8 : 18, 16, Dock.clearance(context)),
          children: [
            if (!pushed) const LargeTitle('Nearby'),
            _meCard(),
            const SizedBox(height: 22),
            const GroupLabel('Find someone nearby'),
            TextField(
              controller: _query,
              textInputAction: TextInputAction.search,
              onSubmitted: _search,
              decoration: InputDecoration(
                hintText: 'Lawyer, doctor, electrician…',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _query.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear',
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => setState(() {
                          _query.clear();
                          _searched = null;
                          _people = const [];
                        }),
                      ),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 38,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: chips.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (_, i) => ActionChip(
                  label: Text(chips[i]),
                  onPressed: () => _search(chips[i]),
                ),
              ),
            ),
            const SizedBox(height: 18),
            ..._results(),
          ],
        ),
      ),
    );
  }

  Widget _meCard() {
    final has = _profession.isNotEmpty;
    // A GroupedCard, as the You tab draws the same two rows: a Column
    // inside the glow card has no height to size against (sweep render).
    return GroupedCard(
      dividerInset: 60,
      children: [
        AppleRow(
          leading: IconTile(Icons.badge_rounded, AppleColors.teal),
          title: _loadingMe
              ? 'Loading…'
              : (has ? _profession : 'Add your profession'),
          subtitle: has
              ? (_shared
                  ? 'People nearby can find you${_area.isNotEmpty ? ' · $_area' : ''}'
                  : 'Only you can see this until you switch sharing on')
              : 'Tell people nearby what you do',
          trailing: Icon(Icons.edit_rounded, color: Neon.textDim, size: 18),
          onTap: _loadingMe ? null : _editProfession,
        ),
        AppleRow(
          leading: IconTile(Icons.near_me_rounded, AppleColors.green),
          title: 'Be found by people nearby',
          subtitle:
              'Shows your profession and area — never your exact location or number',
          trailing: Switch.adaptive(
            value: _shared,
            onChanged: has && !_loadingMe ? _setShared : null,
          ),
        ),
      ],
    );
  }

  List<Widget> _results() {
    if (_searching) {
      return const [NeonLoader.page(semanticLabel: 'Looking around you')];
    }
    if (_needsLocation) {
      return const [
        NeonEmptyState(
          icon: Icons.location_off_rounded,
          title: 'Turn on location',
          body:
              'I need your location to look around you. Allow it in Settings and try again.',
          tone: NeonTone.action,
        ),
      ];
    }
    final q = _searched;
    if (q == null) {
      return [
        Text(
          'People on this app who share their profession show up here. '
          'For shops and offices, just ask: "find lawyers near me".',
          style: TextStyle(
              color: Neon.textDim, fontSize: NeonType.footnote, height: 1.4),
        ),
      ];
    }
    if (_people.isEmpty) {
      return [
        NeonEmptyState(
          icon: Icons.person_search_rounded,
          title: 'No one nearby yet',
          body:
              'Nobody on the app near you has shared "$q". Ask me by voice for real places: '
              '"find $q near me".',
          tone: NeonTone.success,
        ),
      ];
    }
    return [
      GroupLabel('${_people.length} nearby'),
      GroupedCard(
        dividerInset: 60,
        children: [
          for (final p in _people)
            AppleRow(
              leading: IconTile(Icons.person_rounded, AppleColors.blue),
              title: (p['name'] ?? '').toString(),
              subtitle: [
                (p['profession'] ?? '').toString(),
                if ((p['area'] ?? '').toString().isNotEmpty)
                  (p['area'] ?? '').toString(),
                '${p['distanceKm']} km',
              ].join(' · '),
              titleMaxLines: 1,
              trailing: TextButton.icon(
                onPressed: () => _message(p),
                icon: const Icon(Icons.chat_bubble_rounded, size: 16),
                label: const Text('Message'),
              ),
            ),
        ],
      ),
    ];
  }
}
