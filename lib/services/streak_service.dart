import 'package:shared_preferences/shared_preferences.dart';

/// DAILY STREAK — how many days in a row the app has been opened.
///
/// Stored as a date string, not a timestamp: "did they come back today"
/// is a calendar question, and a timestamp makes a user who opens the app
/// at 11:58pm and again at 12:02am look like a two-day streak.
class StreakService {
  StreakService._();
  static final StreakService instance = StreakService._();

  static const _kCount = 'streak_count_v1';
  static const _kBest = 'streak_best_v1';
  static const _kLastDay = 'streak_last_day_v1';

  int count = 0;
  int best = 0;
  bool grewToday = false; // true the first time it is opened on a new day

  static String _day(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// Call once per launch/resume. Safe to call repeatedly.
  Future<void> touch() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final today = _day(DateTime.now());
      final last = prefs.getString(_kLastDay);
      count = prefs.getInt(_kCount) ?? 0;
      best = prefs.getInt(_kBest) ?? 0;
      grewToday = false;

      if (last == today) return; // already counted today
      final yesterday = _day(DateTime.now().subtract(const Duration(days: 1)));
      count = (last == yesterday) ? count + 1 : 1;
      grewToday = true;
      if (count > best) best = count;

      await prefs.setString(_kLastDay, today);
      await prefs.setInt(_kCount, count);
      await prefs.setInt(_kBest, best);
    } catch (_) {
      // Storage unavailable — a missing streak must never block the app.
    }
  }
}
