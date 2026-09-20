/// The daily line for the Home page's bottom quote card (his spec,
/// 2026-09-18 via the phone bridge: "in the homepage and in the bottom i
/// need inspirational quotes"). Local and deterministic — rotates once
/// per day, no network, no repeats on consecutive days.
class DailyQuotes {
  static const _lines = <String>[
    'Small steps today become big wins tomorrow.',
    'Well begun is half done.',
    'Focus on the next right thing.',
    'Discipline today, freedom tomorrow.',
    'Make time for what matters most.',
    'A calm mind gets more done.',
    'Progress, not perfection.',
    'The best time to start is now.',
    'Little by little becomes a lot.',
    'Do one thing your future self will thank you for.',
    'Energy follows action — start small.',
    'Clarity comes from doing, not waiting.',
    'Every expert was once a beginner.',
    'Consistency beats intensity.',
    'Attention is a superpower — spend it well.',
    'Slow is smooth, and smooth is fast.',
    'Plant today what you want to harvest tomorrow.',
    'Strong days are built one choice at a time.',
    'Keep the promises you make to yourself first.',
    'A clear day is a chance to build ahead.',
    'Momentum starts with one small move.',
    'Breathe. Prioritise. Begin.',
    'Done is better than perfect.',
    'Great days are designed, not found.',
  ];

  static String today() {
    final days = DateTime.now().difference(DateTime(2026)).inDays;
    return _lines[days % _lines.length];
  }
}
