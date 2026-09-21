/// The daily line on the Home page.
///
/// His spec, 2026-09-18: "in the homepage and in the bottom i need
/// inspirational quotes". Revised 2026-09-21: "instead of inspirational
/// quotes give motivation quotes."
///
/// The difference is not decorative. An inspirational line is something
/// to agree with — "a calm mind gets more done" — and you nod at it and
/// scroll past. A motivational line asks for something: start, finish,
/// decide, send it, do the hard one first. These are written to be read
/// at 8 a.m. by somebody who has a day in front of them and is putting
/// it off.
///
/// Still local and deterministic: rotates once per day, no network, no
/// repeat on consecutive days.
class DailyQuotes {
  static const _lines = <String>[
    'Do the hard one first. The rest of the day gets easier.',
    'Start before you feel ready — readiness comes from starting.',
    'One hour of real work beats a day of getting ready to work.',
    'The task you keep moving down the list is the one to do now.',
    'Finish something today. Anything.',
    'Send it. A good thing shipped beats a perfect thing waiting.',
    'Decide now. A made decision frees the mind a pending one occupies.',
    'You do not need motivation. You need the first five minutes.',
    'Pick the call you are dreading and make it.',
    'Close one open loop before you open another.',
    'Your future self is watching. Give them something to work with.',
    'Show up today whether you feel like it or not — that is the whole trick.',
    'The work you avoid is usually the work that pays.',
    'Say no to one thing today so you can finish another.',
    'Do it badly, then make it better. Nothing improves in your head.',
    'Two hard hours today are worth ten distracted ones tomorrow.',
    'The day is yours until someone else spends it. Spend it first.',
    'Stop planning it. Open it and begin.',
    'Momentum is built, not found. Build some before lunch.',
    'Answer the message you have been avoiding.',
    'Effort compounds quietly, then all at once.',
    'Do today what your excuses are saving for tomorrow.',
    'Small and finished beats big and imagined.',
    'Discipline is choosing what you want most over what you want now.',
    'Every day you delay, the task grows. Take it while it is small.',
  ];

  static String today() {
    final days = DateTime.now().difference(DateTime(2026)).inDays;
    return _lines[days % _lines.length];
  }
}
