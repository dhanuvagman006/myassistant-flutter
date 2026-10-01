import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/log.dart';
import '../design/apple_kit.dart';
import '../design/neon_tokens.dart';
import '../design/neon_widgets.dart' show NeonLoader, NeonScaffold;
import '../features/calendar/calendar_models.dart';
import '../features/calendar/calendar_service.dart';
import '../features/calendar/calendar_widgets.dart';
import '../features/assistant/state/assistant_engine.dart';
import '../features/home/weather_forecast.dart';
import '../services/app_feedback.dart';
import '../widgets/month_calendar.dart';
import '../widgets/neon_cards.dart';

/// CALENDAR — the month on its own page (2026-09-29), and since
/// 2026-09-30 much more than a month (owner: "in the calendar screen I need
/// much more information, not just a calendar — holidays, upcoming events,
/// maybe global events or anything").
///
/// Top to bottom:
///  1. TODAY — the date, the next holiday, and the week's weather;
///  2. THE MONTH — your busy days shaded, a dot per kind (holiday, festival,
///     meeting, to-do, money, world), holidays' numbers in red;
///  3. THE PICKED DAY — its holidays and your things, with times, the
///     weather when it is in the forecast; your own items deletable;
///  4. COMING UP — the next two months of holidays, festivals, events,
///     reminders, birthdays, bills and meetings, in one list;
///  5. HOLIDAYS & FESTIVALS this month (Kerala's list, banks closed marked);
///  6. AROUND THE WORLD this month — UN days and global events.
///
/// Your things come from GET /brief/calendar; the world's from
/// GET /tools/calendar/extras (saved on the phone, so it paints at once and
/// works offline); the weather from Home's forecast.
class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  /// How far "Coming up" looks.
  static const upcomingDays = 60;
  static const upcomingMax = 8;

  late DateTime _today;
  late int _y, _m;
  late DateTime _selected;

  /// The shown month's own items, from the grid.
  Map<int, List<CalendarEntry>> _mine = const {};
  bool _mineLoaded = false;

  /// The world's days per month ("2026-10") and the months that failed.
  final Map<String, List<CalendarEntry>> _world = {};
  final Set<String> _worldFailed = {};
  String? _region;

  /// "Coming up": the world's next two months and your own.
  List<CalendarEntry>? _upWorld;
  bool _upWorldFailed = false;
  List<CalendarEntry>? _upMine;

  int _refresh = 0;
  final _wx = WeatherForecastService.instance;

  @override
  void initState() {
    super.initState();
    _today = DateUtils.dateOnly(DateTime.now());
    _y = _today.year;
    _m = _today.month;
    _selected = _today;
    _loadMonthWorld(_y, _m);
    _loadUpcoming();
    _wx.addListener(_onWeather);
    unawaited(_wx.load().catchError((_) {}));
  }

  @override
  void dispose() {
    _wx.removeListener(_onWeather);
    super.dispose();
  }

  void _onWeather() {
    if (mounted) setState(() {});
  }

  String _mk(int y, int m) => '$y-$m';

  // ── loading ─────────────────────────────────────────────────────────
  Future<void> _loadMonthWorld(int y, int m, {bool force = false}) async {
    final k = _mk(y, m);
    final from = DateTime(y, m, 1), to = DateTime(y, m + 1, 0);
    void take(ExtrasResult r) {
      if (!mounted) return;
      setState(() {
        _world[k] = r.items;
        _worldFailed.remove(k);
        _region = r.region ?? _region;
      });
    }

    final r = await CalendarService.extras(from, to,
        onSaved: take, force: force);
    if (!mounted) return;
    if (r == null) {
      setState(() => _worldFailed.add(k));
    } else {
      take(r);
    }
  }

  Future<void> _loadUpcoming({bool force = false}) async {
    final to = _today.add(const Duration(days: upcomingDays));
    unawaited(() async {
      void take(ExtrasResult r) {
        if (!mounted) return;
        setState(() {
          _upWorld = r.items;
          _upWorldFailed = false;
          _region = r.region ?? _region;
        });
      }

      final r = await CalendarService.extras(_today, to,
          onSaved: take, force: force);
      if (!mounted) return;
      if (r == null) {
        setState(() => _upWorldFailed = _upWorld == null);
      } else {
        take(r);
      }
    }());

    // Your own things, month by month across the window.
    final months = <(int, int)>[];
    for (var d = DateTime(_today.year, _today.month);
        !d.isAfter(to);
        d = DateTime(d.year, d.month + 1)) {
      months.add((d.year, d.month));
    }
    final got = await Future.wait([
      for (final (y, m) in months)
        CalendarService.month(y, m)
            .then((v) => v ?? CalendarService.cachedMonth(y, m)),
    ]);
    if (!mounted) return;
    final now = DateTime.now();
    final list = <CalendarEntry>[
      for (final byDay in got)
        if (byDay != null)
          for (final day in byDay.values)
            for (final e in day)
              if (!e.date.isBefore(_today) &&
                  !e.date.isAfter(to) &&
                  // Today's already-past times are behind you (a class
                  // still running is not).
                  (e.at == null || (e.endAt ?? e.at!).isAfter(now)))
                e,
    ];
    setState(() => _upMine = list);
  }

  Future<void> _refreshAll() async {
    HapticFeedback.selectionClick();
    setState(() => _refresh++);
    CalendarService.forget(_y, _m);
    await Future.wait([
      _loadMonthWorld(_y, _m, force: true),
      _loadUpcoming(force: true),
      _wx.refresh().catchError((_) {}),
    ]);
  }

  Future<void> _delete(CalendarEntry e) async {
    HapticFeedback.mediumImpact();
    final ok = await CalendarService.remove(e);
    if (!mounted) return;
    if (!ok) {
      AppFeedback.showRetry("Couldn't delete that. Check your connection.",
          context: context, onRetry: () => _delete(e));
      return;
    }
    setState(() {
      _mine = {
        for (final kv in _mine.entries)
          kv.key: kv.value.where((x) => !identical(x, e)).toList(),
      };
      _upMine = _upMine?.where((x) => x.id != e.id || x.del != e.del).toList();
      _refresh++; // the grid fetches its month again
    });
  }

  /// "ADD TO THIS DAY" (2026-09-30): the assistant asks what and when, in
  /// her voice, with the picked day already known — the user only has to
  /// say "lunch with Anil at one".
  void _addOn(DateTime day) {
    HapticFeedback.selectionClick();
    final when = DateUtils.isSameDay(day, _today) ? 'today' : calDayLong(day);
    unawaited(AssistantEngine.instance
        .askAssistant('I want to add something on $when. Ask me what it is '
            'and at what time, then set it as a reminder or a meeting.')
        .catchError((Object e) {
      AppLog.add('calendar', 'add on $when failed: $e');
      if (mounted) {
        AppFeedback.show("Couldn't start that. Tap the mic and tell me.",
            context: context);
      }
    }));
  }

  // ── derived ─────────────────────────────────────────────────────────
  Map<int, List<CalendarEntry>> _worldByDay(int y, int m) {
    final out = <int, List<CalendarEntry>>{};
    for (final e in _world[_mk(y, m)] ?? const <CalendarEntry>[]) {
      // A multi-day event is marked on its first day only (a fortnight of
      // dots would drown the month); the day's agenda lists it throughout.
      if (e.date.year != y || e.date.month != m) continue;
      (out[e.date.day] ??= []).add(e);
    }
    return out;
  }

  List<CalendarEntry> _worldOn(DateTime day) {
    final src = [
      ...?_world[_mk(day.year, day.month)],
      // Early in a month, an event that began last month.
      ...?_upWorld,
    ];
    final seen = <String>{};
    return [
      for (final e in src)
        if (e.covers(day) && seen.add('${e.kind}|${e.title}|${e.date}')) e,
    ]..sort((a, b) => _worldRank(a).compareTo(_worldRank(b)));
  }

  static int _worldRank(CalendarEntry e) => switch (e.kind) {
        'holiday' => 0,
        'festival' => 1,
        'event' => 2,
        _ => 3,
      };

  WeatherDay? _weatherOn(DateTime day) {
    for (final d in _wx.forecast?.days ?? const <WeatherDay>[]) {
      if (DateUtils.isSameDay(d.date, day)) return d;
    }
    return null;
  }

  List<CalendarEntry> get _upcoming {
    final soonWorld = _today.add(const Duration(days: 14));
    final world = (_upWorld ?? const <CalendarEntry>[]).where((e) {
      final start = e.date.isBefore(_today) ? _today : e.date;
      if (e.end == null && e.date.isBefore(_today)) return false;
      // World days are small news: only the next fortnight's.
      if (e.kind == 'world_day') return !start.isAfter(soonWorld);
      // An event already under way is not "coming up".
      return !e.date.isBefore(_today);
    });
    final all = [...world, ...?_upMine]..sort((a, b) {
        final c = a.date.compareTo(b.date);
        if (c != 0) return c;
        final r = (a.isWorld ? _worldRank(a) : 4) - (b.isWorld ? _worldRank(b) : 4);
        if (r != 0) return r;
        return (a.at ?? a.date).compareTo(b.at ?? b.date);
      });
    return all.take(upcomingMax).toList();
  }

  CalendarEntry? get _nextHoliday {
    for (final e in _upWorld ?? const <CalendarEntry>[]) {
      if (e.kind == 'holiday' && !e.date.isBefore(_today)) return e;
    }
    return null;
  }

  /// THE NEXT "US" DAY (2026-09-30, couples): an anniversary from the
  /// saved person dates, which arrive with the rest of your own things in
  /// [_upMine] (the same /brief/calendar rows as a birthday). An older
  /// backend may send it as a birthday row, so a title that says
  /// "anniversary" counts too.
  CalendarEntry? get _nextAnniversary {
    CalendarEntry? best;
    for (final e in _upMine ?? const <CalendarEntry>[]) {
      final isUs = e.kind == 'anniversary' ||
          e.title.toLowerCase().contains('anniversary');
      if (!isUs || e.date.isBefore(_today)) continue;
      if (best == null || e.date.isBefore(best.date)) best = e;
    }
    return best;
  }

  // ── build ───────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return NeonScaffold(
      appBar: appleAppBar(context, 'Calendar'),
      body: RefreshIndicator(
        onRefresh: _refreshAll,
        color: Neon.violet,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(20, 8, 20, 32 + bottom),
          children: [
            _todayCard(),
            const SizedBox(height: Neon.s5),
            MonthCalendar(
              extrasFor: _worldByDay,
              refreshToken: _refresh,
              onDaySelected: (d) => setState(() => _selected = d),
              onMonthChanged: (y, m) {
                setState(() {
                  _y = y;
                  _m = m;
                  _mine = const {};
                  _mineLoaded = false;
                });
                if (!_world.containsKey(_mk(y, m))) _loadMonthWorld(y, m);
              },
              onMonthItems: (y, m, days) {
                if (y != _y || m != _m) return;
                setState(() {
                  _mine = days;
                  _mineLoaded = true;
                });
              },
            ),
            const SizedBox(height: Neon.s6),
            ..._dayAgenda(),
            const SizedBox(height: Neon.s6),
            ..._comingUp(),
            const SizedBox(height: Neon.s6),
            ..._monthHolidays(),
            ..._aroundTheWorld(),
          ],
        ),
      ),
    );
  }

  Widget _todayCard() {
    final next = _nextHoliday;
    final us = _nextAnniversary;
    final days = _wx.forecast?.days ?? const <WeatherDay>[];
    final todayWx = _weatherOn(_today);
    return GlassCard(
      wash: Neon.violet,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              ShaderMask(
                blendMode: BlendMode.srcIn,
                shaderCallback: (r) => Neon.gBrand.createShader(r),
                child: Text('${_today.day}',
                    style: NeonType.manrope(46, FontWeight.w800).copyWith(
                        height: 1.0,
                        color: Colors.white,
                        fontFeatures: NeonType.figures)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(calWeekdays[_today.weekday - 1],
                        style: NeonType.eyebrow.copyWith(color: Neon.textLo)),
                    const SizedBox(height: 2),
                    Semantics(
                      header: true,
                      child: Text(
                          '${calMonths[_today.month - 1]} ${_today.year}',
                          style: NeonType.glassTitle
                              .copyWith(color: Neon.textHi)),
                    ),
                  ],
                ),
              ),
              if (todayWx != null)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Icon(skyIcon(todayWx.sky),
                        size: 26, color: skyColor(todayWx.sky)),
                    if (todayWx.maxC != null)
                      Text('${todayWx.maxC!.round()}°',
                          style: NeonType.manrope(
                                  NeonType.headline, FontWeight.w700)
                              .copyWith(
                                  color: Neon.textHi,
                                  fontFeatures: NeonType.figures)),
                  ],
                ),
            ],
          ),
          if (next != null) ...[
            const SizedBox(height: 14),
            Semantics(
              label:
                  'Next holiday: ${next.title}, ${calDayLong(next.date)}, ${calRelative(next.date, _today).toLowerCase()}',
              child: ExcludeSemantics(
                child: Container(
                  padding: const EdgeInsets.fromLTRB(10, 8, 12, 8),
                  decoration: BoxDecoration(
                    color: NeonTone.danger.fill,
                    borderRadius: BorderRadius.circular(Neon.rSm),
                    border: Border.all(
                        color: NeonTone.danger.rim.first
                            .withValues(alpha: 0.4)),
                  ),
                  child: Row(children: [
                    Icon(Icons.beach_access_rounded,
                        size: 18, color: NeonTone.danger.ink),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text.rich(
                        TextSpan(children: [
                          TextSpan(
                              text: 'Next holiday  ',
                              style: TextStyle(color: Neon.textLo)),
                          TextSpan(
                              text: next.title,
                              style: NeonType.manrope(
                                      NeonType.body, FontWeight.w700)
                                  .copyWith(color: Neon.textHi)),
                        ]),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: NeonType.body),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                        '${calDayShort(next.date)} · ${calRelative(next.date, _today)}',
                        style: NeonType.manrope(
                                NeonType.footnote, FontWeight.w600)
                            .copyWith(color: Neon.textHi)),
                  ]),
                ),
              ),
            ),
          ],
          if (us != null) ...[
            const SizedBox(height: 8),
            _usStrip(us),
          ],
          if (days.isNotEmpty) ...[
            const SizedBox(height: 14),
            Divider(height: 1, thickness: 1, color: Neon.hairline),
            const SizedBox(height: 12),
            CalWeekWeather(days, today: _today),
          ],
        ],
      ),
    );
  }

  /// "💗 12 days to Anu's anniversary": the holiday strip's twin, in the
  /// partner's pink.
  Widget _usStrip(CalendarEntry us) {
    final n = us.date.difference(_today).inDays;
    final line = n == 0
        ? '${us.title} is today'
        : '$n day${n == 1 ? '' : 's'} to ${us.title}';
    return Semantics(
      label: line,
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 8, 12, 8),
          decoration: BoxDecoration(
            color: Neon.pink.withValues(alpha: Neon.isDark ? 0.16 : 0.08),
            borderRadius: BorderRadius.circular(Neon.rSm),
            border: Border.all(color: Neon.pink.withValues(alpha: 0.4)),
          ),
          child: Row(children: [
            const Text('💗', style: TextStyle(fontSize: NeonType.body)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(line,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: NeonType.manrope(NeonType.body, FontWeight.w700)
                      .copyWith(color: Neon.textHi)),
            ),
            const SizedBox(width: 8),
            Text(calDayShort(us.date),
                style: NeonType.manrope(NeonType.footnote, FontWeight.w600)
                    .copyWith(color: Neon.textHi)),
          ]),
        ),
      ),
    );
  }

  List<Widget> _dayAgenda() {
    final world = _worldOn(_selected);
    final inShownMonth = _selected.year == _y && _selected.month == _m;
    final mine = inShownMonth
        ? (_mine[_selected.day] ?? const <CalendarEntry>[])
        : const <CalendarEntry>[];
    final wx = _weatherOn(_selected);
    final isToday = DateUtils.isSameDay(_selected, _today);
    return [
      Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    isToday
                        ? 'Today'
                        : calRelative(_selected, _today),
                    style: NeonType.eyebrow.copyWith(color: Neon.textLo)),
                const SizedBox(height: 2),
                Semantics(
                  header: true,
                  child: Text(calDayLong(_selected),
                      style: NeonType.cardTitle.copyWith(color: Neon.textHi)),
                ),
              ],
            ),
          ),
          if (wx != null) CalWeatherChip(wx),
          if (!_selected.isBefore(_today)) ...[
            const SizedBox(width: 6),
            IconButton(
              tooltip: 'Add to this day',
              onPressed: () => _addOn(_selected),
              style: IconButton.styleFrom(
                minimumSize: const Size(44, 44),
                foregroundColor: NeonTone.brand.ink,
                backgroundColor: NeonTone.brand.fill,
              ),
              icon: const Icon(Icons.add_rounded, size: 22),
            ),
          ],
        ],
      ),
      const SizedBox(height: Neon.s3),
      for (final e in world) CalEntryRow(e, today: _today),
      if (!_mineLoaded && world.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: Center(
              child: NeonLoader.inline(semanticLabel: "Loading the day")),
        )
      else ...[
        for (final e in mine)
          CalEntryRow(e,
              today: _today,
              onDelete: e.deletable ? () => _delete(e) : null),
        if (world.isEmpty && mine.isEmpty)
          CalInlineState(
            icon: Icons.event_available_rounded,
            text: _selected.isBefore(_today)
                ? 'Nothing was planned.'
                : 'Nothing planned yet.',
            actionLabel: _selected.isBefore(_today) ? null : 'Add',
            onAction:
                _selected.isBefore(_today) ? null : () => _addOn(_selected),
          ),
      ],
    ];
  }

  List<Widget> _comingUp() {
    final items = _upcoming;
    final loading = _upMine == null || (_upWorld == null && !_upWorldFailed);
    return [
      const CalSectionHeader(
        icon: Icons.upcoming_rounded,
        title: 'Coming up',
        tone: NeonTone.brand,
      ),
      if (items.isEmpty && loading)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: Center(
              child: NeonLoader.inline(semanticLabel: 'Loading what is coming up')),
        )
      else if (items.isEmpty && _upWorldFailed)
        CalInlineState(
          icon: Icons.cloud_off_rounded,
          tone: NeonTone.danger,
          text: "Couldn't load what's coming up.",
          onRetry: () => _loadUpcoming(force: true),
        )
      else if (items.isEmpty)
        const CalInlineState(
          icon: Icons.event_available_rounded,
          text: 'A clear two months ahead.',
        )
      else
        for (final e in items) CalEntryRow(e, today: _today, showDate: true),
    ];
  }

  List<Widget> _monthHolidays() {
    final k = _mk(_y, _m);
    final list = (_world[k] ?? const <CalendarEntry>[])
        .where((e) =>
            (e.kind == 'holiday' || e.kind == 'festival') &&
            e.date.month == _m &&
            e.date.year == _y)
        .toList();
    final holidays = list.where((e) => e.kind == 'holiday').length;
    final month = calMonths[_m - 1];
    return [
      CalSectionHeader(
        icon: Icons.beach_access_rounded,
        title: 'Holidays & festivals in $month',
        tone: NeonTone.danger,
        trailing: holidays == 0
            ? null
            : '$holidays holiday${holidays == 1 ? '' : 's'}',
      ),
      if (list.isEmpty && _worldFailed.contains(k))
        CalInlineState(
          icon: Icons.cloud_off_rounded,
          tone: NeonTone.danger,
          text: "Couldn't load this month's holidays.",
          onRetry: () => _loadMonthWorld(_y, _m, force: true),
        )
      else if (list.isEmpty && !_world.containsKey(k))
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: Center(
              child: NeonLoader.inline(semanticLabel: 'Loading holidays')),
        )
      else if (list.isEmpty)
        CalInlineState(
          icon: Icons.work_outline_rounded,
          text: 'No public holidays in $month.',
        )
      else ...[
        for (final e in list) CalEntryRow(e, today: _today, showDate: true),
        Padding(
          padding: const EdgeInsets.only(top: 2, bottom: Neon.s2),
          child: Text(
              _region == 'IN'
                  ? 'Central Government list. Eid and Muharram depend on the moon.'
                  : "Kerala Government list. Eid and Muharram depend on the moon.",
              style: TextStyle(
                  color: Neon.textLo, fontSize: NeonType.caption, height: 1.4)),
        ),
      ],
      const SizedBox(height: Neon.s5),
    ];
  }

  List<Widget> _aroundTheWorld() {
    final list = (_world[_mk(_y, _m)] ?? const <CalendarEntry>[])
        .where((e) => e.kind == 'world_day' || e.kind == 'event')
        .toList();
    if (list.isEmpty) return const [];
    return [
      CalSectionHeader(
        icon: Icons.public_rounded,
        title: 'Around the world in ${calMonths[_m - 1]}',
        tone: NeonTone.tip,
      ),
      for (final e in list) CalEntryRow(e, today: _today, showDate: true),
    ];
  }
}
