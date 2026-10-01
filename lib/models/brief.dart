/// The "Today" brief — everything the home dashboard shows, fetched in ONE
/// request (GET /brief) so the busy-professional home screen never spins
/// through five loaders. Mirrors backend src/routes/brief.js.
class TodayBrief {
  final String? weatherLine; // "Partly cloudy · 24°C" or null
  final WeatherNote? weatherNote; // rain on its way, heat, strong sun
  final String? screenTime; // "4h 10m yesterday · most: YouTube 2h 5m"
  final List<AgendaItem> agenda; // reminders + meetings, time-sorted
  final List<AgendaItem> tomorrow; // tomorrow's timed ones (Home, evening)
  final List<DateItem> dates; // birthdays and bills, today or tomorrow
  final List<PromiseItem> promises; // open commitments
  final List<BriefMessage> messages; // unread agent-to-agent messages
  final List<CirclePerson> people; // contacts who are on the app
  final int peopleCount;
  final List<Headline> headlines; // top news, free RSS

  const TodayBrief({
    this.weatherLine,
    this.weatherNote,
    this.screenTime,
    this.agenda = const [],
    this.tomorrow = const [],
    this.dates = const [],
    this.promises = const [],
    this.messages = const [],
    this.people = const [],
    this.peopleCount = 0,
    this.headlines = const [],
  });

  bool get isEmpty =>
      agenda.isEmpty && promises.isEmpty && messages.isEmpty && people.isEmpty;

  /// One-line summary for the collapsed pill.
  String get summary {
    final parts = <String>[];
    if (agenda.isNotEmpty) {
      parts.add('${agenda.length} on your plate');
    }
    if (messages.isNotEmpty) {
      parts.add('${messages.length} message${messages.length == 1 ? '' : 's'}');
    }
    if (promises.isNotEmpty) {
      parts.add('${promises.length} promise${promises.length == 1 ? '' : 's'}');
    }
    if (parts.isEmpty) return 'All clear today';
    return parts.join(' · ');
  }

  factory TodayBrief.fromJson(Map<String, dynamic> j) {
    List<T> list<T>(String k, T Function(Map<String, dynamic>) f) =>
        ((j[k] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(f)
            .toList();
    return TodayBrief(
      weatherLine: j['weather_line'] as String?,
      weatherNote: j['weather_note'] is Map<String, dynamic>
          ? WeatherNote.fromJson(j['weather_note'] as Map<String, dynamic>)
          : null,
      screenTime: j['screen_time'] as String?,
      agenda: list('agenda', AgendaItem.fromJson),
      // Both empty from a server older than 2026-09-29.
      tomorrow: list('tomorrow', AgendaItem.fromJson),
      dates: list('dates', DateItem.fromJson),
      promises: list('promises', PromiseItem.fromJson),
      messages: list('messages', BriefMessage.fromJson),
      people: list('people', CirclePerson.fromJson),
      peopleCount: (j['people_count'] as num?)?.toInt() ?? 0,
      headlines: list('headlines', Headline.fromJson),
    );
  }
}

class Headline {
  final String title;
  final String source;
  final String url; // article link — empty on old servers
  const Headline({required this.title, required this.source, this.url = ''});

  factory Headline.fromJson(Map<String, dynamic> j) => Headline(
        title: j['title'] as String? ?? '',
        source: j['source'] as String? ?? '',
        url: j['url'] as String? ?? '',
      );
}

class AgendaItem {
  final String kind; // 'reminder' | 'meeting'
  final int? id; // reminder id — meetings have none (they live in Google)
  final String title;
  final int? atMs; // epoch ms, null = undated

  /// The Google event behind a meeting (2026-09-30): Home's Prepare opens
  /// Meeting Prep for exactly this one. Null for reminders and old servers.
  final String? eventId;
  const AgendaItem(
      {required this.kind, this.id, required this.title, this.atMs, this.eventId});

  factory AgendaItem.fromJson(Map<String, dynamic> j) => AgendaItem(
        kind: j['kind'] as String? ?? 'reminder',
        id: (j['id'] as num?)?.toInt(),
        title: j['title'] as String? ?? '',
        atMs: (j['at'] as num?)?.toInt(),
        eventId: j['event_id'] as String?,
      );
}

/// "PLAY MY MORNING" (2026-09-30): the brief as a spoken script
/// (POST /brief/script). Mirrors backend src/services/briefScript.js.
class BriefScript {
  const BriefScript({
    required this.part,
    required this.title,
    required this.script,
    this.sentences = const [],
    this.seconds = 0,
    this.offer,
    this.source = 'template',
    this.empty = false,
  });

  /// 'morning' | 'afternoon' | 'evening'.
  final String part;

  /// "Your morning" — the now-playing strip's heading.
  final String title;
  final String script;

  /// The script's sentences, in order (the captions).
  final List<String> sentences;

  /// About how long it takes to say.
  final int seconds;

  /// The one helpful offer it ends with, as a button.
  final BriefOffer? offer;

  /// 'ai' or 'template' (written by code when the model was not sure).
  final String source;

  /// Nothing on the day at all.
  final bool empty;

  /// [sentences], or the script cut at full stops for an older server.
  List<String> get lines {
    if (sentences.isNotEmpty) return sentences;
    return script
        .split(RegExp(r'(?<=[.!?])\s+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  factory BriefScript.fromJson(Map<String, dynamic> j) => BriefScript(
        part: j['part'] as String? ?? 'morning',
        title: j['title'] as String? ?? 'Your day',
        script: (j['script'] as String? ?? '').trim(),
        sentences: ((j['sentences'] as List?) ?? const [])
            .whereType<String>()
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList(),
        seconds: (j['seconds'] as num?)?.toInt() ?? 0,
        offer: j['offer'] is Map<String, dynamic>
            ? BriefOffer.fromJson(j['offer'] as Map<String, dynamic>)
            : null,
        source: j['source'] as String? ?? 'template',
        empty: j['empty'] == true,
      );
}

/// What the spoken brief offers at its end: [kind] 'meeting_prep' opens
/// Meeting Prep ([meetingId] when known), 'ask' hands [request] to the
/// assistant, 'talk' opens the mic.
class BriefOffer {
  const BriefOffer({
    required this.kind,
    required this.say,
    required this.label,
    this.request = '',
    this.meetingId,
  });

  final String kind;
  final String say;
  final String label;
  final String request;
  final String? meetingId;

  factory BriefOffer.fromJson(Map<String, dynamic> j) => BriefOffer(
        kind: j['kind'] as String? ?? 'talk',
        say: j['say'] as String? ?? '',
        label: j['label'] as String? ?? 'Talk to me',
        request: j['request'] as String? ?? '',
        meetingId: j['meetingId'] as String?,
      );
}

class PromiseItem {
  final int? id; // commitment id — needed to complete/dismiss from the UI
  final String text; // "To Ravi: Send the quote" when it is owed to someone
  final String? dueLabel; // "by Friday" style, server-rendered
  final int? dueAtMs; // epoch ms; null = no deadline (or an older server)
  final String? owedTo; // who is waiting on it
  const PromiseItem(
      {this.id, required this.text, this.dueLabel, this.dueAtMs, this.owedTo});

  factory PromiseItem.fromJson(Map<String, dynamic> j) {
    final owed = (j['owed_to'] as String?)?.trim() ?? '';
    return PromiseItem(
      id: (j['id'] as num?)?.toInt(),
      text: j['text'] as String? ?? '',
      dueLabel: j['due_label'] as String?,
      dueAtMs: (j['due_at'] as num?)?.toInt(),
      owedTo: owed.isEmpty ? null : owed,
    );
  }
}

/// The weather worth knowing about in the next hours (the server sends
/// none on an ordinary day).
class WeatherNote {
  final String kind; // 'rain' | 'heat' | 'sun'
  final String text; // "Rain likely 5 pm to 7 pm"
  final String? from; // "17:00", when rain starts
  const WeatherNote({required this.kind, required this.text, this.from});

  factory WeatherNote.fromJson(Map<String, dynamic> j) => WeatherNote(
        kind: j['kind'] as String? ?? '',
        text: j['text'] as String? ?? '',
        from: j['from'] as String?,
      );
}

/// A birthday or a bill that falls today or tomorrow.
class DateItem {
  final String kind; // 'birthday' | 'payment'
  final String title; // "Amma's birthday", "Home loan EMI · ₹12000"
  final String? person; // whose birthday
  final String when; // 'today' | 'tomorrow'
  const DateItem(
      {required this.kind, required this.title, this.person, required this.when});

  factory DateItem.fromJson(Map<String, dynamic> j) => DateItem(
        kind: j['kind'] as String? ?? '',
        title: j['title'] as String? ?? '',
        person: j['person'] as String?,
        when: j['when'] as String? ?? 'today',
      );
}

class BriefMessage {
  final String from;
  final String text;
  const BriefMessage({required this.from, required this.text});

  factory BriefMessage.fromJson(Map<String, dynamic> j) => BriefMessage(
        from: j['from'] as String? ?? 'Someone',
        text: j['text'] as String? ?? '',
      );
}

class CirclePerson {
  final String name;
  final String phone; // empty when the server withheld it
  const CirclePerson({required this.name, this.phone = ''});

  factory CirclePerson.fromJson(Map<String, dynamic> j) => CirclePerson(
        name: j['name'] as String? ?? '',
        phone: j['phone'] as String? ?? '',
      );
}
