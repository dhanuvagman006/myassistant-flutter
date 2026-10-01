import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/api_service.dart';
import '../../services/notification_service.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  HOME'S WEATHER (2026-09-30, owner: "need more visual… instead of a
///  simple rain card need weather card in the home page", with a forecast
///  card as the example). Now, the next 24 hours and the week, from
///  GET /tools/weather/forecast (Open-Meteo on the server, free), saved on
///  the phone so the card is there the moment Home opens.
/// ─────────────────────────────────────────────────────────────────────────

/// What the sky is doing, from the WMO code the forecast uses.
enum Sky { clear, partly, cloudy, fog, drizzle, rain, storm, snow }

Sky skyOf(int? code) => switch (code) {
      0 || 1 => Sky.clear,
      2 => Sky.partly,
      3 => Sky.cloudy,
      45 || 48 => Sky.fog,
      51 || 53 || 55 || 56 || 57 => Sky.drizzle,
      61 || 63 || 65 || 66 || 67 || 80 || 81 || 82 => Sky.rain,
      71 || 73 || 75 || 77 || 85 || 86 => Sky.snow,
      95 || 96 || 99 => Sky.storm,
      _ => Sky.cloudy,
    };

/// The words for a sky, the way a person says them.
String skyWords(Sky s, {required bool day}) => switch (s) {
      Sky.clear => day ? 'Sunny' : 'Clear',
      Sky.partly => 'Partly cloudy',
      Sky.cloudy => 'Cloudy',
      Sky.fog => 'Foggy',
      Sky.drizzle => 'Drizzle',
      Sky.rain => 'Rain',
      Sky.storm => 'Thunderstorm',
      Sky.snow => 'Snow',
    };

double? _d(Object? v) => v is num ? v.toDouble() : null;

class WeatherNow {
  const WeatherNow({this.tempC, this.feelsC, this.humidity, this.windKmh,
      this.visibilityKm, this.uv, this.code, this.isDay = true});
  final double? tempC, feelsC, humidity, windKmh, visibilityKm, uv;
  final int? code;
  final bool isDay;
  Sky get sky => skyOf(code);

  factory WeatherNow.fromJson(Map<String, dynamic> j) => WeatherNow(
        tempC: _d(j['tempC']),
        feelsC: _d(j['feelsC']),
        humidity: _d(j['humidity']),
        windKmh: _d(j['windKmh']),
        visibilityKm: _d(j['visibilityKm']),
        uv: _d(j['uv']),
        code: (j['code'] as num?)?.toInt(),
        isDay: j['isDay'] != false,
      );
}

class WeatherHour {
  const WeatherHour({required this.at, this.tempC, this.rainChance = 0, this.mm = 0,
      this.code, this.isDay = true});
  final DateTime at;
  final double? tempC;
  final double rainChance, mm;
  final int? code;
  final bool isDay;
  Sky get sky => skyOf(code);

  static WeatherHour? fromJson(Map<String, dynamic> j) {
    final at = DateTime.tryParse('${j['at']}');
    if (at == null) return null;
    return WeatherHour(
      at: at,
      tempC: _d(j['tempC']),
      rainChance: _d(j['rainChance']) ?? 0,
      mm: _d(j['mm']) ?? 0,
      code: (j['code'] as num?)?.toInt(),
      isDay: j['isDay'] != false,
    );
  }
}

class WeatherDay {
  const WeatherDay({required this.date, this.maxC, this.minC, this.mm = 0,
      this.rainChance = 0, this.code, this.windKmh, this.uv});
  final DateTime date;
  final double? maxC, minC, windKmh, uv;
  final double mm, rainChance;
  final int? code;
  Sky get sky => skyOf(code);

  static WeatherDay? fromJson(Map<String, dynamic> j) {
    final d = DateTime.tryParse('${j['date']}');
    if (d == null) return null;
    return WeatherDay(
      date: d,
      maxC: _d(j['maxC']),
      minC: _d(j['minC']),
      mm: _d(j['mm']) ?? 0,
      rainChance: _d(j['rainChance']) ?? 0,
      code: (j['code'] as num?)?.toInt(),
      windKmh: _d(j['windKmh']),
      uv: _d(j['uv']),
    );
  }
}

class Forecast {
  const Forecast({required this.now, this.label, this.hours = const [], this.days = const [],
      this.rainFrom, this.rainTo, required this.fetchedAt});
  final WeatherNow now;
  final String? label;
  final List<WeatherHour> hours;
  final List<WeatherDay> days;

  /// The first stretch in the next 12 hours worth an umbrella ("14:00").
  final String? rainFrom, rainTo;
  final DateTime fetchedAt;

  WeatherDay? get today => days.isEmpty ? null : days.first;

  static Forecast? fromJson(Map<String, dynamic> j, {DateTime? fetchedAt}) {
    final now = j['now'];
    if (now is! Map<String, dynamic>) return null;
    final rw = j['rainWindow'];
    return Forecast(
      now: WeatherNow.fromJson(now),
      label: (j['label'] as String?)?.trim().isEmpty ?? true ? null : (j['label'] as String).trim(),
      hours: (j['hours'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(WeatherHour.fromJson)
          .whereType<WeatherHour>()
          .toList(),
      days: (j['days'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(WeatherDay.fromJson)
          .whereType<WeatherDay>()
          .toList(),
      rainFrom: rw is Map ? rw['from'] as String? : null,
      rainTo: rw is Map ? rw['to'] as String? : null,
      fetchedAt: fetchedAt ?? DateTime.tryParse('${j['_at']}') ?? DateTime.now(),
    );
  }
}

/// The forecast Home shows: saved copy first, then the network.
class WeatherForecastService extends ChangeNotifier {
  WeatherForecastService._();
  static final WeatherForecastService instance = WeatherForecastService._();

  static const _cacheKey = 'wx_forecast_v1';
  static const _umbrellaKey = 'wx_umbrella_v1';

  /// A forecast this old is fetched again (Home's minute tick asks).
  static const staleAfter = Duration(minutes: 20);

  Forecast? forecast;
  bool _loading = false;
  bool _loadedCache = false;

  /// "<date> <from>" of the rain an umbrella reminder is already set for.
  String? umbrellaSetFor;

  /// Test seam: what GET /tools/weather/forecast answers.
  @visibleForTesting
  static Future<Map<String, dynamic>?> Function() fetch =
      () => ApiService.getJson('/tools/weather/forecast', timeout: const Duration(seconds: 12));

  /// Test seam: POST /reminders.
  @visibleForTesting
  static Future<bool> Function(String text, DateTime due) createReminder =
      (text, due) async {
    try {
      await ApiService.createReminder(text, due);
      unawaited(ReminderNotifications.instance.sync());
      return true;
    } catch (_) {
      return false;
    }
  };

  /// The saved copy (instant), then a fresh one when it is stale.
  Future<void> load() async {
    if (!_loadedCache) {
      _loadedCache = true;
      try {
        final prefs = await SharedPreferences.getInstance();
        umbrellaSetFor = prefs.getString(_umbrellaKey);
        final raw = prefs.getString(_cacheKey);
        if (raw != null && forecast == null) {
          final f = Forecast.fromJson(jsonDecode(raw) as Map<String, dynamic>);
          if (f != null) {
            forecast = f;
            notifyListeners();
          }
        }
      } catch (_) {}
    }
    await refreshIfStale();
  }

  Future<void> refreshIfStale() async {
    final f = forecast;
    if (f != null && DateTime.now().difference(f.fetchedAt) < staleAfter) return;
    await refresh();
  }

  Future<void> refresh() async {
    if (_loading) return;
    _loading = true;
    try {
      final j = await fetch();
      final at = DateTime.now();
      final f = j == null ? null : Forecast.fromJson(j, fetchedAt: at);
      if (f != null) {
        forecast = f;
        notifyListeners();
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_cacheKey, jsonEncode({...j!, '_at': at.toIso8601String()}));
        } catch (_) {}
      }
    } finally {
      _loading = false;
    }
  }

  /// When an umbrella reminder for this rain would go off: half an hour
  /// before it, or null when that is already past (it is raining, or
  /// about to).
  DateTime? umbrellaTime(DateTime now) {
    final from = forecast?.rainFrom;
    if (from == null) return null;
    final h = int.tryParse(from.split(':').first);
    if (h == null) return null;
    var start = DateTime(now.year, now.month, now.day, h);
    if (start.isBefore(now.subtract(const Duration(hours: 1)))) {
      start = start.add(const Duration(days: 1));
    }
    final at = start.subtract(const Duration(minutes: 30));
    return at.isAfter(now.add(const Duration(minutes: 5))) ? at : null;
  }

  String _umbrellaId(DateTime at) => '${at.year}-${at.month}-${at.day} ${forecast?.rainFrom}';

  bool umbrellaDone(DateTime at) => umbrellaSetFor == _umbrellaId(at);

  /// THE BUTTON ANSWERS AT ONCE (owner, 2026-09-30: "buttons are laggy…
  /// like umbrella reminder"): it used to hand a sentence to the assistant
  /// — a whole conversation turn before anything happened. Now it is set
  /// straight away on the screen, the reminder is made in one call behind
  /// it, and a failure puts the button back.
  Future<bool> remindUmbrella(DateTime at, String rainLabel) async {
    final id = _umbrellaId(at);
    final before = umbrellaSetFor;
    umbrellaSetFor = id;
    notifyListeners();
    final ok = await createReminder('Take an umbrella — rain from $rainLabel', at);
    if (!ok) {
      umbrellaSetFor = before;
      notifyListeners();
      return false;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_umbrellaKey, id);
    } catch (_) {}
    return true;
  }

  @visibleForTesting
  void debugSet(Forecast? f, {String? umbrella}) {
    forecast = f;
    umbrellaSetFor = umbrella;
    _loadedCache = true;
    notifyListeners();
  }
}
