import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../design/neon_tokens.dart';
import '../../design/neon_widgets.dart';
import '../../services/app_feedback.dart';
import '../../widgets/neon_cards.dart';
import 'weather_forecast.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  HOME'S WEATHER CARD (2026-09-30, the owner's example: a forecast card
///  with the day's sky, the temperature, and the week's highs, lows and
///  rain). In the app's light: a sky painted for the weather (sun glow,
///  rain streaks, stars at night), a drawn picture of it, four quick facts,
///  and the rain worth an umbrella with a one-tap reminder. (The week's
///  chart came out the same day — owner: "only this much is enough".)
///  Nothing here animates: it is painted once and cached, so Home scrolls
///  as smoothly as before.
/// ─────────────────────────────────────────────────────────────────────────
class WeatherCard extends StatefulWidget {
  const WeatherCard(
      {super.key, required this.forecast, this.clock = DateTime.now});

  final Forecast forecast;
  final DateTime Function() clock;

  @override
  State<WeatherCard> createState() => _WeatherCardState();
}

class _WeatherCardState extends State<WeatherCard> {
  Forecast get f => widget.forecast;

  static Color get _sun => NeonTone.warning.rim.first;
  static Color get _ember => NeonTone.warning.rim.last;
  static Color get _rain => Neon.cyan;

  @override
  Widget build(BuildContext context) {
    final now = f.now;
    final today = f.today;
    final words = skyWords(now.sky, day: now.isDay);
    final t = now.tempC;
    final place = f.label;
    final label = [
      'Weather: $words',
      if (t != null) '${t.round()} degrees',
      if (now.feelsC != null) 'feels like ${now.feelsC!.round()}',
      if (today?.maxC != null && today?.minC != null)
        'high ${today!.maxC!.round()}, low ${today.minC!.round()}',
      if (f.rainFrom != null) 'rain likely from ${_clock(f.rainFrom!)}',
    ].join(', ');
    return Semantics(
      container: true,
      label: label,
      // Glass, like every card on Home (2026-09-30, premium pass): the sky
      // painted inside it, the hairline edge over it, no neon rim.
      child: GlassCard(
        padding: EdgeInsets.zero,
        clip: true,
        child: RepaintBoundary(
          child: CustomPaint(
            painter: _SkyPainter(now.sky, now.isDay),
            child: Padding(
              padding:
                  const EdgeInsets.fromLTRB(Neon.s5, Neon.s5, Neon.s5, Neon.s4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ExcludeSemantics(
                    child: Row(
                      children: [
                        SizedBox(
                          width: 76,
                          height: 68,
                          child: CustomPaint(
                              painter: WeatherArt(now.sky, now.isDay)),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(words,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: NeonType.glassTitle
                                      .copyWith(color: Neon.textHi)),
                              const SizedBox(height: 2),
                              Text(_placeLine(place, f.fetchedAt),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      color: Neon.textLo,
                                      fontSize: NeonType.footnote)),
                            ],
                          ),
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(t == null ? '—' : '${t.round()}°',
                                style: GoogleFonts.spaceGrotesk(
                                  fontSize: 44,
                                  height: 1.0,
                                  fontWeight: FontWeight.w500,
                                  letterSpacing: -1,
                                  color: Neon.textHi,
                                  fontFeatures: NeonType.figures,
                                )),
                            const SizedBox(height: Neon.s1),
                            if (today?.maxC != null && today?.minC != null)
                              Text(
                                  'H ${today!.maxC!.round()}°  L ${today.minC!.round()}°',
                                  style: NeonType.manrope(
                                          NeonType.footnote, FontWeight.w600)
                                      .copyWith(
                                          color: Neon.textLo,
                                          fontFeatures: NeonType.figures)),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: Neon.s4),
                  ExcludeSemantics(child: _facts(now)),
                  if (f.rainFrom != null) ...[
                    const SizedBox(height: Neon.s3),
                    // Its own listener: the button answers the tap even
                    // where nothing above rebuilds the card.
                    ListenableBuilder(
                      listenable: WeatherForecastService.instance,
                      builder: (_, __) => _rainRow(),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _facts(WeatherNow now) {
    // ONE QUIET PANEL (premium pass): four facts in columns split by
    // hairlines, not four boxed tiles; the icon small beside its name.
    Widget fact(IconData icon, String value, String name, Color tint) =>
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Neon.s3),
            child: Column(
              children: [
                Text(value,
                    maxLines: 1,
                    style: NeonType.manrope(NeonType.callout, FontWeight.w700)
                        .copyWith(
                            color: Neon.textHi,
                            fontFeatures: NeonType.figures)),
                const SizedBox(height: 2),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(icon, size: 12, color: tint.withValues(alpha: 0.9)),
                    const SizedBox(width: 3),
                    Flexible(
                      child: Text(name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: Neon.textLo, fontSize: NeonType.caption)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
    Widget rule() => Container(width: 1, height: 28, color: Neon.hairline);
    return Container(
      decoration: BoxDecoration(
        color: Neon.bg.withValues(alpha: 0.28),
        borderRadius: BorderRadius.circular(Neon.rInner),
        border: Border.all(color: Neon.hairline),
      ),
      child: Row(
        children: [
          fact(
              Icons.thermostat_rounded,
              now.feelsC == null ? '—' : '${now.feelsC!.round()}°',
              'Feels',
              _ember),
          rule(),
          fact(
              Icons.water_drop_rounded,
              now.humidity == null ? '—' : '${now.humidity!.round()}%',
              'Humidity',
              _rain),
          rule(),
          fact(
              Icons.air_rounded,
              now.windKmh == null ? '—' : '${now.windKmh!.round()} km/h',
              'Wind',
              Neon.textLo),
          rule(),
          fact(Icons.wb_sunny_outlined,
              now.uv == null ? '—' : now.uv!.round().toString(), 'UV', _sun),
        ],
      ),
    );
  }

  Widget _rainRow() {
    final svc = WeatherForecastService.instance;
    final at = svc.umbrellaTime(widget.clock());
    final from = _clock(f.rainFrom!);
    final to = f.rainTo == null ? null : _clock(f.rainTo!);
    final done = at != null && svc.umbrellaDone(at);
    return Container(
      padding: const EdgeInsets.fromLTRB(Neon.s3, Neon.s1, Neon.s1, Neon.s1),
      decoration: BoxDecoration(
        color: _rain.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(Neon.rInner),
        border: Border.all(color: _rain.withValues(alpha: 0.22)),
      ),
      child: Row(
        children: [
          Icon(Icons.umbrella_rounded, size: 20, color: _rain),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
                to == null
                    ? 'Rain likely from $from'
                    : 'Rain likely $from – $to',
                maxLines: 2,
                style: NeonType.manrope(NeonType.footnote, FontWeight.w600)
                    .copyWith(color: Neon.textHi)),
          ),
          if (at != null)
            NeonPill(
              label: done ? 'Set for ${_time(at)}' : 'Remind me',
              icon: done ? Icons.check_rounded : Icons.alarm_add_rounded,
              tone: done ? NeonTone.success : NeonTone.info,
              quiet: true,
              onPressed: done ? null : () => _remind(at, from),
            ),
        ],
      ),
    );
  }

  Future<void> _remind(DateTime at, String from) async {
    HapticFeedback.lightImpact();
    AppFeedback.show("I'll remind you at ${_time(at)} to take an umbrella.",
        context: context, tone: FeedbackTone.success);
    final ok = await WeatherForecastService.instance.remindUmbrella(at, from);
    if (!ok && mounted) {
      AppFeedback.showRetry("Couldn't set the reminder. Check your connection.",
          context: context, onRetry: () => _remind(at, from));
    }
  }

  /// "14:00" → "2 pm".
  static String _clock(String hhmm) {
    final h = int.tryParse(hhmm.split(':').first) ?? 0;
    return _hourWords(h);
  }

  static String _time(DateTime t) {
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m ${t.hour < 12 ? 'am' : 'pm'}';
  }
}

String _hourWords(int h) {
  if (h == 0) return '12 am';
  if (h == 12) return '12 pm';
  return h < 12 ? '$h am' : '${h - 12} pm';
}

/// The card's sky: a wash for the weather and the time of day — the sun's
/// glow, rain streaks, stars — painted once.
class _SkyPainter extends CustomPainter {
  _SkyPainter(this.sky, this.day);
  final Sky sky;
  final bool day;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final bg = Neon.bg;
    final blue = NeonTone.info.rim.first;
    final (topC, glow, glowAt) = switch (sky) {
      Sky.clear when day => (
          Color.lerp(blue, bg, 0.45)!,
          NeonTone.warning.rim.first,
          const Alignment(-0.85, -0.9)
        ),
      Sky.clear => (
          Color.lerp(Neon.violet, bg, 0.72)!,
          Neon.textHi,
          const Alignment(-0.85, -0.9)
        ),
      Sky.partly => (
          Color.lerp(blue, bg, 0.55)!,
          day ? NeonTone.warning.rim.first : Neon.textLo,
          const Alignment(-0.85, -0.9)
        ),
      Sky.cloudy || Sky.fog => (
          Color.lerp(Neon.textLo, bg, 0.78)!,
          Neon.textLo,
          const Alignment(0, -1.2)
        ),
      Sky.drizzle || Sky.rain => (
          Color.lerp(Neon.cyan, bg, 0.78)!,
          Neon.cyan,
          const Alignment(-0.7, -1.1)
        ),
      Sky.storm => (
          Color.lerp(Neon.violet, bg, 0.6)!,
          Neon.violet,
          const Alignment(0.6, -1.0)
        ),
      Sky.snow => (
          Color.lerp(Neon.cyan, bg, 0.7)!,
          Neon.textHi,
          const Alignment(0, -1.1)
        ),
    };
    canvas.drawRect(
        rect,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [topC, Color.lerp(Neon.surface, bg, 0.3)!],
          ).createShader(rect));
    canvas.drawRect(
        rect,
        Paint()
          ..shader = RadialGradient(
            center: glowAt,
            radius: 0.9,
            colors: [glow.withValues(alpha: 0.28), glow.withValues(alpha: 0)],
          ).createShader(rect));

    final rnd = math.Random(7);
    if (sky == Sky.clear && !day) {
      final star = Paint()..color = Neon.textHi.withValues(alpha: 0.7);
      for (var i = 0; i < 26; i++) {
        final p = Offset(rnd.nextDouble() * size.width,
            rnd.nextDouble() * size.height * 0.45);
        canvas.drawCircle(p, rnd.nextDouble() * 1.2 + 0.4, star);
      }
    }
    if (sky == Sky.rain || sky == Sky.drizzle || sky == Sky.storm) {
      final streak = Paint()
        ..color = Neon.cyan.withValues(alpha: sky == Sky.drizzle ? 0.07 : 0.11)
        ..strokeWidth = 1.2
        ..strokeCap = StrokeCap.round;
      for (var i = 0; i < 70; i++) {
        final p = Offset(
            rnd.nextDouble() * size.width, rnd.nextDouble() * size.height);
        final len = 10 + rnd.nextDouble() * 16;
        canvas.drawLine(p, p + Offset(-len * 0.28, len), streak);
      }
    }
  }

  @override
  bool shouldRepaint(_SkyPainter old) => old.sky != sky || old.day != day;
}

/// THE PICTURE OF THE WEATHER: a glowing sun, a moon, clouds, rain, a bolt
/// or snow — drawn, not an icon, so it can glow like the rest of the app.
class WeatherArt extends CustomPainter {
  WeatherArt(this.sky, this.day);
  final Sky sky;
  final bool day;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final sunC = NeonTone.warning.rim.first;
    final ember = NeonTone.warning.rim.last;

    void sun(Offset c, double r) {
      canvas.drawCircle(
          c,
          r * 2.1,
          Paint()
            ..shader = RadialGradient(colors: [
              sunC.withValues(alpha: 0.45),
              sunC.withValues(alpha: 0)
            ]).createShader(Rect.fromCircle(center: c, radius: r * 2.1)));
      final ray = Paint()
        ..color = sunC.withValues(alpha: 0.9)
        ..strokeWidth = r * 0.16
        ..strokeCap = StrokeCap.round;
      for (var i = 0; i < 8; i++) {
        final a = i * math.pi / 4;
        final d = Offset(math.cos(a), math.sin(a));
        canvas.drawLine(c + d * r * 1.32, c + d * r * 1.62, ray);
      }
      canvas.drawCircle(
          c,
          r,
          Paint()
            ..shader = RadialGradient(
              center: const Alignment(-0.3, -0.35),
              colors: [Neon.textHi, sunC, ember],
              stops: const [0, 0.45, 1],
            ).createShader(Rect.fromCircle(center: c, radius: r)));
    }

    void moon(Offset c, double r) {
      canvas.drawCircle(
          c,
          r * 1.9,
          Paint()
            ..shader = RadialGradient(colors: [
              Neon.textHi.withValues(alpha: 0.25),
              Neon.textHi.withValues(alpha: 0)
            ]).createShader(Rect.fromCircle(center: c, radius: r * 1.9)));
      final shape = Path.combine(
        PathOperation.difference,
        Path()..addOval(Rect.fromCircle(center: c, radius: r)),
        Path()
          ..addOval(Rect.fromCircle(
              center: c + Offset(r * 0.55, -r * 0.35), radius: r * 0.85)),
      );
      canvas.drawPath(shape, Paint()..color = Neon.textHi);
    }

    Path cloudPath(Offset c, double w) {
      final h = w * 0.5;
      final base = Rect.fromCenter(
          center: c + Offset(0, h * 0.25), width: w, height: h * 0.55);
      return Path()
        ..addRRect(RRect.fromRectAndRadius(base, Radius.circular(h * 0.28)))
        ..addOval(Rect.fromCircle(
            center: c + Offset(-w * 0.18, h * 0.02), radius: h * 0.36))
        ..addOval(Rect.fromCircle(
            center: c + Offset(w * 0.12, -h * 0.12), radius: h * 0.48));
    }

    void cloud(Offset c, double w, {bool dark = false}) {
      final p = cloudPath(c, w);
      canvas.drawPath(
          p.shift(const Offset(0, 3)),
          Paint()
            ..color = (dark ? Neon.violet : Neon.cyan).withValues(alpha: 0.28)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7));
      final bounds = p.getBounds();
      canvas.drawPath(
          p,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: dark
                  ? [
                      Color.lerp(Neon.textLo, Neon.violet, 0.4)!,
                      Color.lerp(Neon.surfaceHigh, Neon.violet, 0.3)!
                    ]
                  : [Neon.textHi, Color.lerp(Neon.textLo, Neon.cyan, 0.25)!],
            ).createShader(bounds));
    }

    final c = Offset(size.width / 2, size.height / 2);
    switch (sky) {
      case Sky.clear:
        day ? sun(c, s * 0.24) : moon(c, s * 0.28);
      case Sky.partly:
        day
            ? sun(c + Offset(-s * 0.14, -s * 0.12), s * 0.2)
            : moon(c + Offset(-s * 0.12, -s * 0.12), s * 0.2);
        cloud(c + Offset(s * 0.08, s * 0.1), s * 0.78);
      case Sky.cloudy:
        cloud(c + Offset(-s * 0.12, -s * 0.06), s * 0.6, dark: true);
        cloud(c + Offset(s * 0.08, s * 0.06), s * 0.78);
      case Sky.fog:
        cloud(c + Offset(0, -s * 0.12), s * 0.7);
        final fog = Paint()
          ..color = Neon.textLo.withValues(alpha: 0.8)
          ..strokeWidth = s * 0.06
          ..strokeCap = StrokeCap.round;
        for (var i = 0; i < 3; i++) {
          final y = c.dy + s * (0.2 + i * 0.1);
          canvas.drawLine(Offset(c.dx - s * (0.34 - i * 0.06), y),
              Offset(c.dx + s * (0.3 - i * 0.04), y), fog);
        }
      case Sky.drizzle || Sky.rain || Sky.storm:
        cloud(c + Offset(0, -s * 0.12), s * 0.82, dark: sky == Sky.storm);
        if (sky == Sky.storm) {
          final bolt = Path()
            ..moveTo(c.dx + s * 0.02, c.dy + s * 0.06)
            ..lineTo(c.dx - s * 0.1, c.dy + s * 0.26)
            ..lineTo(c.dx + s * 0.0, c.dy + s * 0.26)
            ..lineTo(c.dx - s * 0.08, c.dy + s * 0.46)
            ..lineTo(c.dx + s * 0.14, c.dy + s * 0.2)
            ..lineTo(c.dx + s * 0.04, c.dy + s * 0.2)
            ..lineTo(c.dx + s * 0.12, c.dy + s * 0.06)
            ..close();
          canvas.drawPath(
              bolt,
              Paint()
                ..color = sunC.withValues(alpha: 0.5)
                ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5));
          canvas.drawPath(bolt, Paint()..color = sunC);
        } else {
          final drop = Paint()
            ..color = Neon.cyan
            ..strokeWidth = s * (sky == Sky.drizzle ? 0.035 : 0.05)
            ..strokeCap = StrokeCap.round;
          final n = sky == Sky.drizzle ? 3 : 4;
          for (var i = 0; i < n; i++) {
            final x = c.dx - s * 0.24 + i * s * (0.48 / (n - 1));
            final y = c.dy + s * 0.18 + (i.isOdd ? s * 0.06 : 0);
            canvas.drawLine(
                Offset(x, y), Offset(x - s * 0.05, y + s * 0.16), drop);
          }
        }
      case Sky.snow:
        cloud(c + Offset(0, -s * 0.12), s * 0.8);
        final flake = Paint()..color = Neon.textHi;
        for (var i = 0; i < 4; i++) {
          canvas.drawCircle(
              Offset(c.dx - s * 0.22 + i * s * 0.15,
                  c.dy + s * (0.24 + (i.isOdd ? 0.08 : 0))),
              s * 0.035,
              flake);
        }
    }
  }

  @override
  bool shouldRepaint(WeatherArt old) => old.sky != sky || old.day != day;
}

/// The place, and — once the saved forecast is over two hours old — how
/// old it is, so a stale reading is never passed off as now (2026-10-01).
String _placeLine(String? place, DateTime fetchedAt) {
  final where = place ?? 'Where you are';
  final age = DateTime.now().difference(fetchedAt);
  if (age < const Duration(hours: 2)) return where;
  final ago = age.inHours < 24 ? '${age.inHours} h ago' : '${age.inDays} d ago';
  return '$where · as of $ago';
}
