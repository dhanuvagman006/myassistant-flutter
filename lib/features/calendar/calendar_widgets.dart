import 'package:flutter/material.dart';

import '../../design/neon_tokens.dart';
import '../../widgets/month_calendar.dart' show calendarTone;
import '../../widgets/neon_cards.dart';
import '../home/weather_forecast.dart' show Sky, WeatherDay, skyWords;
import 'calendar_models.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  THE CALENDAR SCREEN'S PIECES (2026-09-30). Built only from the neon
///  system's own parts (RimCard, ToneTile, GlassCard, NeonType, NeonTone):
///  nothing here restyles them. Words never under 12 sp, secondary words in
///  [Neon.textLo] (AA on the card), colour carried by icons and dots rather
///  than by small text.
/// ─────────────────────────────────────────────────────────────────────────

/// A section's title row: its lit tile, the title, an optional count.
class CalSectionHeader extends StatelessWidget {
  const CalSectionHeader({
    super.key,
    required this.icon,
    required this.title,
    this.tone = NeonTone.brand,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final NeonTone tone;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Neon.s3),
      child: Row(
        children: [
          ToneTile(icon, tone),
          const SizedBox(width: 10),
          Expanded(
            child: Semantics(
              header: true,
              child: Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: NeonType.sectionTitle.copyWith(color: Neon.textHi)),
            ),
          ),
          if (trailing != null)
            Text(trailing!,
                style: NeonType.manrope(NeonType.footnote, FontWeight.w600)
                    .copyWith(color: Neon.textLo)),
        ],
      ),
    );
  }
}

/// The day as a small calendar leaf: weekday over a big number, the
/// holiday's red when it is one.
class CalDateBlock extends StatelessWidget {
  const CalDateBlock(this.date, {super.key, this.tone});

  final DateTime date;
  final NeonTone? tone;

  @override
  Widget build(BuildContext context) {
    final t = tone;
    return ExcludeSemantics(
      child: Container(
        width: 48,
        height: 52,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Neon.rTile),
          color: t == null
              ? Color.alphaBlend(
                  Neon.violet.withValues(alpha: Neon.isDark ? 0.10 : 0.06),
                  Neon.surfaceHigh)
              : t.fill,
          border: Border.all(
              color: (t?.rim.first ?? Neon.violet)
                  .withValues(alpha: Neon.isDark ? 0.45 : 0.30)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(calMonthsShort[date.month - 1].toUpperCase(),
                style: NeonType.manrope(NeonType.caption, FontWeight.w700)
                    .copyWith(
                        color: t?.ink ?? Neon.textLo,
                        letterSpacing: 0.6,
                        height: 1.1)),
            Text('${date.day}',
                style: NeonType.manrope(NeonType.title3, FontWeight.w800)
                    .copyWith(
                        color: Neon.textHi,
                        height: 1.1,
                        fontFeatures: NeonType.figures)),
          ],
        ),
      ),
    );
  }
}

/// A small word on a tinted ground: "Banks closed", "Tentative".
class CalTag extends StatelessWidget {
  const CalTag(this.label, {super.key, required this.tone, this.icon});

  final String label;
  final NeonTone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: tone.fill,
        borderRadius: BorderRadius.circular(Neon.rPill),
        border: Border.all(color: tone.rim.first.withValues(alpha: 0.45)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[
          Icon(icon, size: 13, color: tone.ink),
          const SizedBox(width: 4),
        ],
        Text(label,
            style: NeonType.manrope(NeonType.caption, FontWeight.w700)
                .copyWith(color: Neon.textHi, height: 1.2)),
      ]),
    );
  }
}

/// ONE ROW: a holiday, a meeting, a UN day. [showDate] leads with the
/// date leaf (lists across days); otherwise the kind's tile (one day's
/// agenda). A holiday is the one toned card: its red rim says "day off".
class CalEntryRow extends StatelessWidget {
  const CalEntryRow(
    this.e, {
    super.key,
    required this.today,
    this.showDate = false,
    this.onDelete,
  });

  final CalendarEntry e;
  final DateTime today;
  final bool showDate;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final tone = calendarTone(e.kind);
    final isHoliday = e.kind == 'holiday';
    final when = <String>[
      calendarKindLabel(e.kind),
      if (e.at != null) calTimeRange(e.at!, e.endAt),
      if (showDate)
        e.end != null ? calSpan(e.date, e.end!) : calRelative(e.date, today),
      if (!showDate && e.end != null) calSpan(e.date, e.end!),
    ].join(' · ');
    final tags = <Widget>[
      if (e.bank) const CalTag('Banks closed', tone: NeonTone.warning,
          icon: Icons.account_balance_rounded),
      if (e.tentative)
        const CalTag('Date may change', tone: NeonTone.tip),
    ];
    final spoken = [
      e.title,
      calendarKindLabel(e.kind),
      calDayLong(e.date),
      if (e.at != null) calTimeRange(e.at!, e.endAt),
      if (e.bank) 'banks closed',
      if (e.tentative) 'date may change',
      if (e.note != null) e.note!,
    ].join(', ');
    return Padding(
      padding: const EdgeInsets.only(bottom: Neon.s2),
      child: Semantics(
        container: true,
        label: spoken,
        child: RimCard(
          tone: isHoliday ? NeonTone.danger : null,
          radius: Neon.rMd,
          padding: EdgeInsets.fromLTRB(12, 10, onDelete == null ? 12 : 2, 10),
          child: ExcludeSemantics(
            excluding: onDelete == null,
            child: Row(
              children: [
                if (showDate)
                  CalDateBlock(e.date, tone: isHoliday ? NeonTone.danger : null)
                else
                  ToneTile(calendarKindIcon(e.kind), tone, size: 36),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(e.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: NeonType.manrope(
                                  NeonType.body, FontWeight.w700)
                              .copyWith(color: Neon.textHi, height: 1.3)),
                      const SizedBox(height: 3),
                      Row(children: [
                        if (showDate) ...[
                          Icon(calendarKindIcon(e.kind),
                              size: 14, color: tone.ink),
                          const SizedBox(width: 5),
                        ],
                        Expanded(
                          child: Text(when,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: Neon.textLo,
                                  fontSize: NeonType.footnote,
                                  height: 1.3)),
                        ),
                      ]),
                      if (e.note != null) ...[
                        const SizedBox(height: 2),
                        Text(e.note!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: Neon.textLo,
                                fontSize: NeonType.caption,
                                height: 1.3)),
                      ],
                      if (tags.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Wrap(spacing: 6, runSpacing: 4, children: tags),
                      ],
                    ],
                  ),
                ),
                if (onDelete != null)
                  IconButton(
                    tooltip: 'Delete',
                    onPressed: onDelete,
                    icon: Icon(Icons.delete_outline_rounded,
                        size: 20, color: Neon.textLo),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A one-line quiet state inside a section: "Nothing planned", or a
/// failure with its retry (48 dp).
class CalInlineState extends StatelessWidget {
  const CalInlineState({
    super.key,
    required this.icon,
    required this.text,
    this.onRetry,
    this.actionLabel,
    this.onAction,
    this.tone = NeonTone.tip,
  });

  final IconData icon;
  final String text;
  final VoidCallback? onRetry;

  /// A way forward other than a retry ("Add", 2026-09-30): the button's
  /// label and what it does.
  final String? actionLabel;
  final VoidCallback? onAction;
  final NeonTone tone;

  @override
  Widget build(BuildContext context) {
    return RimCard(
      radius: Neon.rMd,
      padding: EdgeInsets.fromLTRB(
          12, 8, onRetry == null && onAction == null ? 12 : 4, 8),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 40),
        child: Row(children: [
          ToneTile(icon, tone, size: 30),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text,
                style: TextStyle(
                    color: Neon.textLo,
                    fontSize: NeonType.body,
                    height: 1.35)),
          ),
          if (onRetry != null)
            TextButton(
              onPressed: onRetry,
              style: TextButton.styleFrom(
                minimumSize: const Size(48, 48),
                foregroundColor: Neon.textHi,
                textStyle:
                    NeonType.manrope(NeonType.body, FontWeight.w700),
              ),
              child: const Text('Try again'),
            ),
          if (onAction != null && actionLabel != null)
            TextButton.icon(
              onPressed: onAction,
              style: TextButton.styleFrom(
                minimumSize: const Size(48, 48),
                foregroundColor: tone.ink,
                textStyle:
                    NeonType.manrope(NeonType.body, FontWeight.w700),
              ),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: Text(actionLabel!),
            ),
        ]),
      ),
    );
  }
}

// ── weather, from Home's forecast ─────────────────────────────────────
IconData skyIcon(Sky s) => switch (s) {
      Sky.clear => Icons.wb_sunny_rounded,
      Sky.partly => Icons.wb_cloudy_rounded,
      Sky.cloudy => Icons.cloud_rounded,
      Sky.fog => Icons.foggy,
      Sky.drizzle => Icons.grain_rounded,
      Sky.rain => Icons.water_drop_rounded,
      Sky.storm => Icons.thunderstorm_rounded,
      Sky.snow => Icons.ac_unit_rounded,
    };

Color skyColor(Sky s) => switch (s) {
      Sky.clear => NeonTone.warning.ink,
      Sky.rain || Sky.drizzle || Sky.storm => NeonTone.info.ink,
      _ => Neon.textLo,
    };

/// "31° / 24° · Rain 60%", for a day of the forecast.
String weatherLine(WeatherDay d) {
  final hi = d.maxC?.round(), lo = d.minC?.round();
  final t = hi == null
      ? ''
      : lo == null
          ? '$hi°'
          : '$hi° / $lo°';
  final rain = d.rainChance >= 30 ? 'Rain ${d.rainChance.round()}%' : skyWords(d.sky, day: true);
  return [if (t.isNotEmpty) t, rain].join(' · ');
}

/// The picked day's weather, as a quiet chip beside its title.
class CalWeatherChip extends StatelessWidget {
  const CalWeatherChip(this.day, {super.key});
  final WeatherDay day;

  @override
  Widget build(BuildContext context) {
    final line = weatherLine(day);
    return Semantics(
      label: 'Weather: $line',
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Neon.rPill),
            color: Neon.surfaceHigh.withValues(alpha: 0.7),
            border: Border.all(color: Neon.hairline),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(skyIcon(day.sky), size: 16, color: skyColor(day.sky)),
            const SizedBox(width: 6),
            Text(line,
                style: NeonType.manrope(NeonType.footnote, FontWeight.w600)
                    .copyWith(color: Neon.textHi, fontFeatures: NeonType.figures)),
          ]),
        ),
      ),
    );
  }
}

/// The week ahead in one row: day, sky, high. Today first.
class CalWeekWeather extends StatelessWidget {
  const CalWeekWeather(this.days, {super.key, required this.today});
  final List<WeatherDay> days;
  final DateTime today;

  @override
  Widget build(BuildContext context) {
    final list = days
        .where((d) => !DateUtils.dateOnly(d.date).isBefore(today))
        .take(7)
        .toList();
    if (list.isEmpty) return const SizedBox.shrink();
    return Row(
      children: [
        for (final d in list)
          Expanded(
            child: Semantics(
              label:
                  '${DateUtils.isSameDay(d.date, today) ? 'Today' : calWeekdays[d.date.weekday - 1]}: ${weatherLine(d)}',
              child: ExcludeSemantics(
                child: Column(children: [
                  Text(
                      DateUtils.isSameDay(d.date, today)
                          ? 'Today'
                          : calWeekdaysShort[d.date.weekday - 1],
                      style: NeonType.manrope(NeonType.caption, FontWeight.w600)
                          .copyWith(color: Neon.textLo)),
                  const SizedBox(height: 5),
                  Icon(skyIcon(d.sky), size: 20, color: skyColor(d.sky)),
                  const SizedBox(height: 5),
                  Text(d.maxC == null ? '–' : '${d.maxC!.round()}°',
                      style: NeonType.manrope(NeonType.footnote, FontWeight.w700)
                          .copyWith(
                              color: Neon.textHi,
                              fontFeatures: NeonType.figures)),
                ]),
              ),
            ),
          ),
      ],
    );
  }
}
