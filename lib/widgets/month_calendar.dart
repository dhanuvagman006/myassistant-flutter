import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/motion.dart';
import '../design/neon_tokens.dart';
import '../design/neon_widgets.dart' show NeonEmptyState, NeonLoader;
import '../features/calendar/calendar_models.dart';
import '../features/calendar/calendar_service.dart';
import '../services/brief_service.dart';
import 'neon_cards.dart';

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
  const MonthCalendar({
    super.key,
    this.extrasFor,
    this.onDaySelected,
    this.onMonthChanged,
    this.onMonthItems,
    this.refreshToken = 0,
  });

  /// THE CALENDAR SCREEN'S MODE (2026-09-30). Holidays, festivals, world
  /// days and events for a shown month, by day: each adds its kind's dot,
  /// and a holiday's number is drawn in the holiday colour. Null on Home.
  final Map<int, List<CalendarEntry>> Function(int year, int month)? extrasFor;

  /// Set, a tap on any day picks it and tells the screen (which shows the
  /// day's agenda itself): no inline list, no day sheet.
  final ValueChanged<DateTime>? onDaySelected;
  final void Function(int year, int month)? onMonthChanged;

  /// The shown month's own items as they arrive (the screen's agenda).
  final void Function(int year, int month, Map<int, List<CalendarEntry>> days)?
      onMonthItems;

  /// Bump to fetch the shown month again (after the screen deletes).
  final int refreshToken;

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
      ].map(_readable).toList();

  /// A busy shade, darkened only as far as its day number needs to read
  /// (4.5:1). The fluorescent accents (2026-09-25) put some shades right
  /// in the middle — the Orange partner by day was 4.35:1 for white AND
  /// for dark numbers — and a fixed per-colour tweak would break again
  /// with the next palette. A shade that already reads is left alone.
  static Color _readable(Color c) {
    double ratio(Color a, Color b) {
      final x = a.computeLuminance(), y = b.computeLuminance();
      return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
    }
    var h = HSLColor.fromColor(c);
    for (var i = 0; i < 16; i++) {
      final col = h.toColor();
      if (ratio(Neon.textOn(col), col) >= 4.5) return col;
      h = h.withLightness((h.lightness - 0.03).clamp(0.0, 1.0));
    }
    return h.toColor();
  }

  @override
  State<MonthCalendar> createState() => _MonthCalendarState();
}

class _MonthCalendarState extends State<MonthCalendar> {
  late int _year;
  late int _month; // 1-12
  int? _selected; // day of month
  Map<int, List<CalendarEntry>> _days = {};
  bool _loading = true;
  DateTime _lastFetch = DateTime.fromMillisecondsSinceEpoch(0);

  static const _mo = [
    'January', 'February', 'March', 'April', 'May', 'June', 'July',
    'August', 'September', 'October', 'November', 'December'
  ];

  // The busy scale (see [MonthCalendar.heatColors]). The name stays so
  // every call site below is untouched.
  static List<Color> get _greens => MonthCalendar.heatColors;

  /// The calendar screen owns the day's agenda (see [MonthCalendar.onDaySelected]).
  bool get _screenMode => widget.onDaySelected != null;

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
  void didUpdateWidget(MonthCalendar old) {
    super.didUpdateWidget(old);
    if (old.refreshToken != widget.refreshToken) {
      CalendarService.forget(_year, _month);
      _fetch();
    }
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

  String get _cacheKey => '$_year-$_month';

  void _setDays(Map<int, List<CalendarEntry>> d) {
    setState(() {
      _days = {for (final e in d.entries) e.key: List.of(e.value)};
      _loading = false;
    });
    widget.onMonthItems?.call(_year, _month, _days);
  }

  Future<void> _fetch() async {
    _lastFetch = DateTime.now();
    // Months already seen this app-run paint at once; the network fetch
    // that follows quietly replaces them.
    final cached = CalendarService.cachedMonth(_year, _month);
    if (cached != null && _days.isEmpty) _setDays(cached);
    final wanted = _cacheKey; // guard against a month switch mid-flight
    final fresh = await CalendarService.month(_year, _month);
    if (!mounted || wanted != _cacheKey) return;
    if (fresh == null) {
      // Network blip: keep whatever is on screen rather than blanking it.
      if (_loading) setState(() => _loading = false);
      widget.onMonthItems?.call(_year, _month, _days);
      return;
    }
    _setDays(fresh);
  }

  /// Which way the last month change went (-1 back, 1 forward): the new
  /// month comes in from that side.
  int _travel = 1;

  void _shiftMonth(int delta) {
    HapticFeedback.selectionClick();
    _travel = delta < 0 ? -1 : 1;
    var y = _year, m = _month + delta;
    if (m < 1) { m = 12; y--; }
    if (m > 12) { m = 1; y++; }
    final now = DateTime.now();
    final isNow = y == now.year && m == now.month;
    setState(() {
      _year = y;
      _month = m;
      _loading = true;
      // On the screen a day is always picked (its agenda is below): today,
      // or the 1st of another month.
      _selected = isNow ? now.day : (_screenMode ? 1 : null);
      _days = {};
    });
    widget.onMonthChanged?.call(y, m);
    if (_screenMode) widget.onDaySelected!(DateTime(y, m, _selected!));
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

  (IconData, NeonTone) _kindBadge(String kind) =>
      (calendarKindIcon(kind), calendarTone(kind));

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
                boxShadow: Neon.halo(Neon.violet, strength: 0.5),
              ),
              child: Icon(Icons.calendar_month_rounded,
                  size: 15, color: Neon.onTile(Neon.violet)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Semantics(
                header: true,
                child: Text('${_mo[_month - 1]} $_year',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: NeonType.sectionTitle.copyWith(color: Neon.textHi)),
              ),
            ),
            _chev(Icons.chevron_left_rounded, 'Previous month',
                () => _shiftMonth(-1)),
            _chev(Icons.chevron_right_rounded, 'Next month',
                () => _shiftMonth(1)),
          ],
        ),
        const SizedBox(height: 4),
        // The month on the raised night card (2026-09-30): a soft rim, so
        // the one glowing thing inside it is the picked day.
        RimCard(
          padding: const EdgeInsets.all(10),
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
              // THE MONTH TURNS, IT DOES NOT CUT (2026-09-24). Changing
              // months swapped the whole grid in one frame. The new month
              // now fades in from the side it was reached from, 16 dp,
              // while the old one fades out.
              AnimatedSwitcher(
                duration: Motion.short,
                reverseDuration: Motion.out,
                switchInCurve: Motion.easeEnter,
                switchOutCurve: Motion.easeFadeOut,
                layoutBuilder: (current, previous) => Stack(
                  alignment: Alignment.topCenter,
                  children: [...previous, if (current != null) current],
                ),
                transitionBuilder: (child, a) => FadeTransition(
                  opacity: a,
                  child: AnimatedBuilder(
                    animation: a,
                    // Only the arriving month moves; the leaving one fades.
                    builder: (_, c) => Transform.translate(
                      offset: Offset(
                          a.status == AnimationStatus.reverse
                              ? 0
                              : 16 * _travel * (1 - a.value),
                          0),
                      child: c,
                    ),
                    // Moved as a layer, not drawn again on every frame.
                    child: RepaintBoundary(child: child),
                  ),
                ),
                child: KeyedSubtree(
                  key: ValueKey('$_year-$_month'),
                  child: _loading
                      ? const Padding(
                          padding: EdgeInsets.symmetric(vertical: 30),
                          child: Center(
                              child: NeonLoader.inline(
                                  semanticLabel: 'Loading the month')),
                        )
                      : Column(
                          children: [
                            for (var r = 0; r < rows; r++)
                              Row(
                                children: [
                                  for (var c = 0; c < 7; c++)
                                    _dayCell(r * 7 + c - leading + 1,
                                        daysInMonth, today),
                                ],
                              ),
                          ],
                        ),
                ),
              ),
              const SizedBox(height: 6),
              // GitHub-style legend, so the shading explains itself. On the
              // calendar screen the dots say more than the shade, so the
              // legend names the kinds instead.
              if (widget.extrasFor != null)
                _kindLegend()
              else
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
        // What's on the selected day (the screen shows its own agenda).
        if (_selected != null && !_loading && !_screenMode) ...[
          const SizedBox(height: 10),
          ..._selectedItems(),
        ],
      ],
    );
  }

  /// What each dot means, in words (the calendar screen).
  Widget _kindLegend() {
    const keys = [
      ('Holiday', NeonTone.danger),
      ('Festival', NeonTone.discovery),
      ('Meeting', NeonTone.info),
      ('To do', NeonTone.action),
      ('Money', NeonTone.warning),
      ('World', NeonTone.tip),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 2, 4, 2),
      child: Wrap(
        spacing: 12,
        runSpacing: 4,
        alignment: WrapAlignment.center,
        children: [
          for (final (label, tone) in keys)
            Row(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 7,
                height: 7,
                decoration:
                    BoxDecoration(shape: BoxShape.circle, color: tone.rim.first),
              ),
              const SizedBox(width: 5),
              Text(label,
                  style: TextStyle(
                      color: Neon.textDim, fontSize: NeonType.caption)),
            ]),
        ],
      ),
    );
  }

  Widget _dayCell(int day, int daysInMonth, DateTime today) {
    // 48 dp to the finger on the calendar screen (the tile and its margin).
    final cellH = _screenMode ? 44.0 : 38.0;
    if (day < 1 || day > daysInMonth) {
      return Expanded(child: SizedBox(height: cellH + 4));
    }
    final items = _days[day] ?? const <CalendarEntry>[];
    final count = items.length;
    // The world's days (holidays, festivals, UN days) add dots but never
    // shade the tile: the shade is how busy YOUR day is.
    final world = widget.extrasFor?.call(_year, _month)[day] ??
        const <CalendarEntry>[];
    final holiday = world.where((e) => e.kind == 'holiday').firstOrNull;
    final isToday =
        _isCurrentMonth && day == today.day;
    final isSelected = day == _selected;
    final filled = count > 0;
    // One dot per KIND of thing on the day, in its meaning's colour
    // (2026-09-30): blue a meeting, magenta-orange something to do, amber
    // money going out, green money coming in. Three at most.
    final tones = <NeonTone>{
      for (final it in world) calendarTone(it.kind),
      for (final it in items) calendarTone(it.kind),
    }.toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    final words = [
      '$day ${_mo[_month - 1]}',
      if (isToday) 'today',
      if (holiday != null) holiday.title,
      if (count > 0) '$count thing${count == 1 ? '' : 's'} on',
    ].join(', ');

    return Expanded(
      child: Tappable(
        scale: 0.92,
        semanticLabel: words,
        tapHint: isToday || _screenMode ? 'show' : 'open',
        onTap: () {
          if (_screenMode) {
            HapticFeedback.selectionClick();
            setState(() => _selected = day);
            widget.onDaySelected!(DateTime(_year, _month, day));
          } else if (isToday) {
            // Today reads inline, right under the grid — same place the
            // agenda lives.
            setState(() => _selected = day);
          } else {
            // Any other day opens the day sheet: the full list, deletable.
            _openDaySheet(day);
          }
        },
        // The highlight moves to the tapped day instead of jumping.
        child: ExcludeSemantics(
          child: AnimatedContainer(
            duration: Motion.micro,
            curve: Motion.easeMove,
            height: cellH,
            margin: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              // THE PICKED DAY IS LIT (2026-09-30): the brand gradient and
              // its halo — the one glowing thing on the month.
              color: isSelected ? null : _tileColor(count),
              gradient: isSelected ? Neon.gBrand : null,
              borderRadius: BorderRadius.circular(8),
              boxShadow:
                  isSelected ? Neon.halo(Neon.violet, strength: 0.8) : null,
              // Today is a cyan ring, the assistant's own light. Empty days
              // have no border at all (see _tileColor).
              border: isToday && !isSelected
                  ? Border.all(color: Neon.cyan, width: 1.6)
                  : null,
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                // 13 sp (was 11.5), in its real weight: today and the
                // picked day are now genuinely heavier, not only asked to be.
                Text(
                  '$day',
                  style: NeonType.manrope(
                          NeonType.footnote,
                          isToday || isSelected
                              ? FontWeight.w800
                              : FontWeight.w500)
                      .copyWith(
                    color: isSelected
                        ? Neon.textOn(Color.lerp(Neon.violet, Neon.pink, 0.5)!)
                        : filled
                            ? Neon.textOn(_tileColor(count))
                            // A holiday's number in the holiday colour, as
                            // on a printed calendar.
                            : holiday != null
                                ? NeonTone.danger.ink
                                : Neon.textLo,
                  ),
                ),
                if (tones.isNotEmpty)
                  Positioned(
                    bottom: 3,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final t in tones.take(3))
                          Container(
                            width: 5,
                            height: 5,
                            margin: const EdgeInsets.symmetric(horizontal: 1),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: t.rim.first,
                              // A dark edge so a dot reads on a busy or
                              // lit tile as well as on the card.
                              border: filled || isSelected
                                  ? Border.all(color: Neon.bg, width: 0.8)
                                  : null,
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _selectedItems() {
    final items = _days[_selected] ?? const <CalendarEntry>[];
    const mo = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final label = '$_selected ${mo[_month - 1]}';
    if (items.isEmpty) {
      return [
        NeonEmptyState(
          icon: Icons.event_available_rounded,
          title: 'Nothing on $label.',
          tone: NeonTone.tip,
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
                final (icon, tone) = _kindBadge(it.kind);
                return ToneTile(icon, tone, size: 26);
              }),
              const SizedBox(width: 9),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    it.title,
                    style: TextStyle(
                        color: Neon.textHi,
                        fontSize: NeonType.footnote,
                        height: 1.3),
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
  Future<bool> _deleteItem(int day, CalendarEntry it) async {
    if (!it.deletable) return false;
    if (!await CalendarService.remove(it)) return false;
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

    // The theme's sheet (2026-09-30): its surface, lit rim and handle. The
    // sheet drew its own on a clear ground, under the theme's handle.
    showAppSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheetCtx) {
        // Said inside the sheet: a toast raised here would land on the
        // page BEHIND it, under the barrier, where nobody sees it.
        String? problem;
        return StatefulBuilder(
        builder: (ctx, setSheet) {
          final items = List<CalendarEntry>.of(_days[day] ?? const []);
          return Padding(
            padding: EdgeInsets.only(
                left: 20,
                right: 20,
                bottom: 24 + MediaQuery.of(ctx).viewPadding.bottom),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Semantics(
                        header: true,
                        child: Text(title,
                            style: NeonType.cardTitle.copyWith(
                                color: Neon.textHi, letterSpacing: -0.2)),
                      ),
                    ),
                    if (items.isNotEmpty)
                      Text(
                          '${items.length} item${items.length == 1 ? '' : 's'}',
                          style: TextStyle(
                              color: Neon.textDim,
                              fontSize: NeonType.footnote)),
                  ],
                ),
                const SizedBox(height: 14),
                if (items.isEmpty)
                  const NeonEmptyState(
                    icon: Icons.event_available_rounded,
                    title: 'Nothing on this day.',
                    tone: NeonTone.tip,
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
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: RimCard(
                              radius: Neon.rSm,
                              padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                              child: Row(
                                children: [
                                  Builder(builder: (_) {
                                    final (icon, tone) = _kindBadge(it.kind);
                                    return ToneTile(icon, tone, size: 30);
                                  }),
                                  const SizedBox(width: 11),
                                  Expanded(
                                    child: Text(
                                      it.title,
                                      style: TextStyle(
                                          color: Neon.textHi,
                                          fontSize: NeonType.body,
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
                                              fontSize: NeonType.caption)),
                                    ),
                                ],
                              ),
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
                            style: TextStyle(
                                color: Neon.errorInk,
                                fontSize: NeonType.footnote)),
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

/// WHAT A DAY'S ITEM MEANS, AS LIGHT (2026-09-30) — the same tones as
/// Home's cards: a meeting is information, a reminder or a promise is
/// something to do, a bill is money going out, income is good news.
/// Public for tests.
NeonTone calendarTone(String kind) => switch (kind) {
      'meeting' => NeonTone.info,
      'payment' => NeonTone.warning,
      'income' => NeonTone.success,
      // The world's days (2026-09-30, the calendar screen): a holiday in
      // red as on a printed calendar, a festival or a birthday is something
      // to celebrate, a world day or a global event is the assistant's
      // "worth knowing".
      'holiday' => NeonTone.danger,
      'festival' || 'birthday' || 'anniversary' => NeonTone.discovery,
      // Lectures (2026-09-30, students): the app's own light, the one tone
      // no other kind uses, so a class is never mistaken for a meeting.
      'class' => NeonTone.brand,
      'event' || 'world_day' => NeonTone.tip,
      _ => NeonTone.action, // reminder, promise
    };
