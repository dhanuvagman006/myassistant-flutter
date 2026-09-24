import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/motion.dart';
import '../design/neon_tokens.dart';
import '../services/api_service.dart';
import '../services/brief_service.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  MONTH CALENDAR — the home screen's commitment heat-map.
///
///  GitHub-contributions style: one compact grid for the month, each day a
///  tile whose green depth = how much is on that day (meetings, payments,
///  incoming money, reminders, promises — everything the user has told
///  their agent). Tap a day to read what's on it. Fed by
///  GET /brief/calendar, which aggregates every source server-side.
/// ─────────────────────────────────────────────────────────────────────────
class MonthCalendar extends StatefulWidget {
  const MonthCalendar({super.key});

  /// THE BUSY SCALE, IN THE BRAND'S OWN COLOURS: one, two, three or more
  /// things on a day.
  ///
  /// These were GitHub's contribution greens, which is why the one busy
  /// day on a violet screen glowed green and read as someone else's
  /// design. Same three-step idea, violet → magenta.
  ///
  /// A GETTER, READ FRESH (2026-09-24). As a static final list it kept
  /// the old accent after a colour change until the app restarted. The
  /// first step is now a pale tint of the accent by day (a dim one by
  /// night), so a one-item day is quiet and its number reads in plain
  /// ink: the old fixed violet-black on #596DDE was 3.77:1. Numbers on
  /// every step take [Neon.textOn], 4.5:1 or better (pinned by
  /// test/contrast_test.dart).
  static List<Color> get heatColors => [
        Neon.isDark
            ? Color.lerp(Neon.violet, Neon.surface, 0.55)!
            : Color.lerp(Neon.violet, Colors.white, 0.62)!,
        Neon.violet,
        // A shade deeper by day: with the Crimson accent the partner was
        // too light for white words and too dark for black ones (4.4:1).
        Neon.isDark
            ? Neon.pink
            : HSLColor.fromColor(Neon.pink)
                .withLightness(HSLColor.fromColor(Neon.pink).lightness * 0.9)
                .toColor(),
      ];

  @override
  State<MonthCalendar> createState() => _MonthCalendarState();
}

class _CalItem {
  final String kind; // meeting | payment | income | reminder | promise
  final String title;

  /// REST collection + id for deletion ("reminders", "commitments",
  /// "finance"); null for Google meetings, which we don't own.
  final String? del;
  final int? id;
  const _CalItem(this.kind, this.title, {this.del, this.id});

  bool get deletable => del != null && id != null;
}

class _MonthCalendarState extends State<MonthCalendar> {
  late int _year;
  late int _month; // 1-12
  int? _selected; // day of month
  Map<int, List<_CalItem>> _days = {};
  bool _loading = true;
  DateTime _lastFetch = DateTime.fromMillisecondsSinceEpoch(0);

  static const _mo = [
    'January', 'February', 'March', 'April', 'May', 'June', 'July',
    'August', 'September', 'October', 'November', 'December'
  ];

  // The busy scale (see [MonthCalendar.heatColors]). The name stays so
  // every call site below is untouched.
  static List<Color> get _greens => MonthCalendar.heatColors;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _year = now.year;
    _month = now.month;
    _selected = now.day;
    _fetch();
    // The agent adds meetings/payments mid-conversation; when the brief
    // refreshes, quietly re-pull the month too (throttled).
    BriefService.instance.addListener(_onBriefChanged);
  }

  @override
  void dispose() {
    BriefService.instance.removeListener(_onBriefChanged);
    super.dispose();
  }

  void _onBriefChanged() {
    // 8s, not 45: the brief refreshing right after a turn is exactly the
    // "something was just created" signal — a new reminder must appear on
    // the month within seconds, not whenever the old guard felt like it.
    if (DateTime.now().difference(_lastFetch).inSeconds > 8) _fetch();
  }

  bool get _isCurrentMonth {
    final now = DateTime.now();
    return _year == now.year && _month == now.month;
  }

  /// Months already seen this app-run — painting these is instant, and the
  /// network fetch that follows quietly replaces them.
  static final Map<String, Map<String, dynamic>> _memCache = {};

  String get _cacheKey => '$_year-$_month';

  Map<int, List<_CalItem>> _parse(Map<String, dynamic>? j) {
    final out = <int, List<_CalItem>>{};
    final raw = (j?['days'] as Map?) ?? {};
    raw.forEach((k, v) {
      final day = int.tryParse(k.toString());
      if (day == null || v is! List) return;
      out[day] = v
          .whereType<Map>()
          .map((e) => _CalItem(
                (e['kind'] as String?) ?? 'reminder',
                (e['title'] as String?) ?? '',
                del: e['del'] as String?,
                id: (e['id'] as num?)?.toInt(),
              ))
          .toList();
    });
    return out;
  }

  Future<void> _fetch() async {
    _lastFetch = DateTime.now();
    // Instant paint from this run's cache while the fresh copy loads.
    final cached = _memCache[_cacheKey];
    if (cached != null && _days.isEmpty) {
      setState(() {
        _days = _parse(cached);
        _loading = false;
      });
    }
    final wanted = _cacheKey; // guard against a month switch mid-flight
    final j = await ApiService.getJson('/brief/calendar?y=$_year&m=$_month');
    if (!mounted || wanted != _cacheKey) return;
    if (j == null) {
      // Network blip: keep whatever is on screen rather than blanking it.
      if (_loading) setState(() => _loading = false);
      return;
    }
    _memCache[_cacheKey] = j;
    setState(() {
      _days = _parse(j);
      _loading = false;
    });
  }

  void _shiftMonth(int delta) {
    HapticFeedback.selectionClick();
    var y = _year, m = _month + delta;
    if (m < 1) { m = 12; y--; }
    if (m > 12) { m = 1; y++; }
    setState(() {
      _year = y;
      _month = m;
      _loading = true;
      final now = DateTime.now();
      _selected = (y == now.year && m == now.month) ? now.day : null;
      _days = {};
    });
    _fetch();
  }

  // EMPTY DAYS ARE PLAIN CARD (2026-09-24). Thirty grey tiles, each with
  // a border at 1.15:1 against the card, filled half of Home with noise
  // even when nothing was on. Only days that hold something are coloured
  // now, so the busy ones are what the eye finds.
  Color _tileColor(int count) {
    if (count <= 0) return Colors.transparent;
    if (count == 1) return _greens[0];
    if (count == 2) return _greens[1];
    return _greens[2];
  }

  (IconData, Color) _kindBadge(String kind) => switch (kind) {
        'meeting' => (Icons.event_rounded, Neon.cyan),
        'payment' => (Icons.currency_rupee_rounded, Neon.error),
        'income' => (Icons.south_west_rounded, _greens[1]),
        'promise' => (Icons.handshake_rounded, Neon.pink),
        _ => (Icons.alarm_rounded, Neon.violet),
      };

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final first = DateTime(_year, _month, 1);
    final daysInMonth = DateTime(_year, _month + 1, 0).day;
    final leading = first.weekday - 1; // Monday-first grid
    final cells = leading + daysInMonth;
    final rows = (cells / 7).ceil();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header: month + arrows in the SAME look as the agenda and
        // promises headers above it. A bare 15 dp icon and 13 sp text made
        // the biggest block on Home look like it came from another app.
        Row(
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                gradient: Neon.tile(Neon.violet),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(Icons.calendar_month_rounded,
                  size: 15, color: Neon.onTile(Neon.violet)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text('${_mo[_month - 1]} $_year',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: NeonType.sectionTitle.copyWith(color: Neon.textHi)),
            ),
            _chev(Icons.chevron_left_rounded, 'Previous month',
                () => _shiftMonth(-1)),
            _chev(Icons.chevron_right_rounded, 'Next month',
                () => _shiftMonth(1)),
          ],
        ),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Neon.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Neon.line),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  for (final d in const ['M', 'T', 'W', 'T', 'F', 'S', 'S'])
                    Expanded(
                      child: Center(
                        child: Text(d,
                            style: NeonType.manrope(
                                    NeonType.caption, FontWeight.w600)
                                .copyWith(color: Neon.textDim)),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              if (_loading)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 30),
                  child: Center(
                      child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Neon.textLo))),
                )
              else
                for (var r = 0; r < rows; r++)
                  Row(
                    children: [
                      for (var c = 0; c < 7; c++)
                        _dayCell(r * 7 + c - leading + 1, daysInMonth, today),
                    ],
                  ),
              const SizedBox(height: 6),
              // GitHub-style legend, so the shading explains itself.
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text('Less',
                      style: TextStyle(
                          color: Neon.textDim, fontSize: NeonType.caption)),
                  const SizedBox(width: 5),
                  // "Nothing on" is an outline, as the empty days are now.
                  for (final c in [Colors.transparent, ..._greens]) ...[
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: c,
                        borderRadius: BorderRadius.circular(2.5),
                        border: Border.all(color: Neon.lineBright, width: 0.5),
                      ),
                    ),
                    const SizedBox(width: 3),
                  ],
                  const SizedBox(width: 2),
                  Text('More',
                      style: TextStyle(
                          color: Neon.textDim, fontSize: NeonType.caption)),
                ],
              ),
            ],
          ),
        ),
        // What's on the selected day.
        if (_selected != null && !_loading) ...[
          const SizedBox(height: 10),
          ..._selectedItems(),
        ],
      ],
    );
  }

  Widget _dayCell(int day, int daysInMonth, DateTime today) {
    if (day < 1 || day > daysInMonth) {
      return const Expanded(child: SizedBox(height: 42));
    }
    final count = _days[day]?.length ?? 0;
    final isToday =
        _isCurrentMonth && day == today.day;
    final isSelected = day == _selected;
    final filled = count > 0;

    return Expanded(
      child: PressScale(
          child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HapticFeedback.selectionClick();
          if (isToday) {
            // Today reads inline, right under the grid — same place the
            // agenda lives.
            setState(() => _selected = day);
          } else {
            // Any other day opens the day sheet: the full list, deletable.
            _openDaySheet(day);
          }
        },
        child: Container(
          height: 38,
          margin: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: _tileColor(count),
            borderRadius: BorderRadius.circular(8),
            // Violet, the app's primary accent — a white ring on a grid
            // of gray tiles never read as "today". Empty days have no
            // border at all (see _tileColor).
            border: isSelected
                ? Border.all(color: Neon.violet, width: 1.6)
                : isToday
                    ? Border.all(
                        color: Neon.violet.withValues(alpha: 0.55),
                        width: 1.2)
                    : null,
          ),
          child: Center(
            // 13 sp (was 11.5), in its real weight: today and the picked
            // day are now genuinely heavier, not only asked to be.
            child: Text(
              '$day',
              style: NeonType.manrope(
                      NeonType.footnote,
                      isToday || isSelected
                          ? FontWeight.w800
                          : FontWeight.w500)
                  .copyWith(
                color: filled ? Neon.textOn(_tileColor(count)) : Neon.textLo,
              ),
            ),
          ),
        ),
      ),
      ),
    );
  }

  List<Widget> _selectedItems() {
    final items = _days[_selected] ?? const <_CalItem>[];
    const mo = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final label = '$_selected ${mo[_month - 1]}';
    if (items.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.only(left: 2),
          // textLo: textDim fell to 3.6:1 on the ambient wash.
          child: Text('Nothing on $label.',
              style:
                  TextStyle(color: Neon.textLo, fontSize: NeonType.footnote)),
        ),
      ];
    }
    return [
      for (final it in items)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Builder(builder: (_) {
                final (icon, color) = _kindBadge(it.kind);
                return Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(icon, size: 14, color: color),
                );
              }),
              const SizedBox(width: 9),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    it.title,
                    style: TextStyle(
                        color: Neon.textHi, fontSize: 13, height: 1.3),
                  ),
                ),
              ),
            ],
          ),
        ),
    ];
  }

  /// 48 dp to the finger (was 28: a 20 px arrow with 4 px around it).
  Widget _chev(IconData icon, String label, VoidCallback onTap) => IconButton(
        tooltip: label,
        onPressed: onTap,
        icon: Icon(icon, size: 22, color: Neon.textLo),
      );

  // ---------------- DAY SHEET (any day but today) ----------------

  /// Deletes [it] server-side and removes it from the month locally, so
  /// the tile shade updates the instant the row disappears.
  Future<bool> _deleteItem(int day, _CalItem it) async {
    if (!it.deletable) return false;
    final r =
        await ApiService.sendJson('/${it.del}/${it.id}', method: 'DELETE');
    if (r == null) return false;
    if (mounted) {
      setState(() {
        _days[day]?.remove(it);
        if (_days[day]?.isEmpty ?? false) _days.remove(day);
      });
    }
    return true;
  }

  void _openDaySheet(int day) {
    const wk = [
      'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday',
      'Sunday'
    ];
    final title =
        '${wk[DateTime(_year, _month, day).weekday - 1]}, $day ${_mo[_month - 1]}';

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetCtx) {
        // Said inside the sheet: a toast raised here would land on the
        // page BEHIND it, under the barrier, where nobody sees it.
        String? problem;
        return StatefulBuilder(
        builder: (ctx, setSheet) {
          final items = List<_CalItem>.of(_days[day] ?? const []);
          return Container(
            decoration: BoxDecoration(
              color: Neon.surface,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(24)),
              border: Border(top: BorderSide(color: Neon.lineBright)),
            ),
            padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 10,
                bottom: 24 + MediaQuery.of(ctx).viewPadding.bottom),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Neon.textDim.withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: Text(title,
                          style: TextStyle(
                              color: Neon.textHi,
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.2)),
                    ),
                    if (items.isNotEmpty)
                      Text(
                          '${items.length} item${items.length == 1 ? '' : 's'}',
                          style: TextStyle(
                              color: Neon.textDim, fontSize: 13)),
                  ],
                ),
                const SizedBox(height: 14),
                if (items.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text('Nothing on this day.',
                        style: TextStyle(
                            color: Neon.textDim, fontSize: 14)),
                  )
                else
                  ConstrainedBox(
                    constraints: BoxConstraints(
                        maxHeight:
                            MediaQuery.of(ctx).size.height * 0.5),
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final it in items)
                          Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                            decoration: BoxDecoration(
                              color: Neon.surfaceHigh,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Neon.line),
                            ),
                            child: Row(
                              children: [
                                Builder(builder: (_) {
                                  final (icon, color) = _kindBadge(it.kind);
                                  return Container(
                                    width: 30,
                                    height: 30,
                                    decoration: BoxDecoration(
                                      color:
                                          color.withValues(alpha: 0.12),
                                      borderRadius:
                                          BorderRadius.circular(9),
                                    ),
                                    child:
                                        Icon(icon, size: 15, color: color),
                                  );
                                }),
                                const SizedBox(width: 11),
                                Expanded(
                                  child: Text(
                                    it.title,
                                    style: TextStyle(
                                        color: Neon.textHi,
                                        fontSize: 14,
                                        height: 1.3),
                                  ),
                                ),
                                if (it.deletable)
                                  IconButton(
                                    tooltip: 'Delete',
                                    icon: Icon(Icons.delete_outline_rounded,
                                        size: 19, color: Neon.textDim),
                                    onPressed: () async {
                                      HapticFeedback.mediumImpact();
                                      final ok =
                                          await _deleteItem(day, it);
                                      if (!ctx.mounted) return;
                                      setSheet(() => problem = ok
                                          ? null
                                          : "Couldn't delete that — check "
                                              'your connection.');
                                    },
                                  )
                                else
                                  Padding(
                                    padding:
                                        const EdgeInsets.only(right: 10),
                                    // From the linked calendar: removed
                                    // there, not here.
                                    child: Text('Calendar',
                                        style: TextStyle(
                                            color: Neon.textDim,
                                            fontSize: 12)),
                                  ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                if (problem != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Row(children: [
                      Icon(Icons.error_outline_rounded,
                          size: 16, color: Neon.error),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(problem!,
                            style:
                                TextStyle(color: Neon.errorInk, fontSize: 13)),
                      ),
                    ]),
                  ),
              ],
            ),
          );
        },
      );
      },
    );
  }
}
