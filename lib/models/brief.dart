/// The "Today" brief — everything the home dashboard shows, fetched in ONE
/// request (GET /brief) so the busy-professional home screen never spins
/// through five loaders. Mirrors backend src/routes/brief.js.
class TodayBrief {
  final String? weatherLine; // "Partly cloudy · 24°C" or null
  final String? screenTime; // "4h 10m yesterday · most: YouTube 2h 5m"
  final List<AgendaItem> agenda; // reminders + meetings, time-sorted
  final List<PromiseItem> promises; // open commitments
  final List<BriefMessage> messages; // unread agent-to-agent messages
  final List<CirclePerson> people; // contacts who are on the app
  final int peopleCount;
  final List<Headline> headlines; // top news, free RSS

  const TodayBrief({
    this.weatherLine,
    this.screenTime,
    this.agenda = const [],
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
      screenTime: j['screen_time'] as String?,
      agenda: list('agenda', AgendaItem.fromJson),
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
  const Headline({required this.title, required this.source});

  factory Headline.fromJson(Map<String, dynamic> j) => Headline(
        title: j['title'] as String? ?? '',
        source: j['source'] as String? ?? '',
      );
}

class AgendaItem {
  final String kind; // 'reminder' | 'meeting'
  final int? id; // reminder id — meetings have none (they live in Google)
  final String title;
  final int? atMs; // epoch ms, null = undated
  const AgendaItem(
      {required this.kind, this.id, required this.title, this.atMs});

  factory AgendaItem.fromJson(Map<String, dynamic> j) => AgendaItem(
        kind: j['kind'] as String? ?? 'reminder',
        id: (j['id'] as num?)?.toInt(),
        title: j['title'] as String? ?? '',
        atMs: (j['at'] as num?)?.toInt(),
      );
}

class PromiseItem {
  final int? id; // commitment id — needed to complete/dismiss from the UI
  final String text;
  final String? dueLabel; // "by Friday" style, server-rendered
  const PromiseItem({this.id, required this.text, this.dueLabel});

  factory PromiseItem.fromJson(Map<String, dynamic> j) => PromiseItem(
        id: (j['id'] as num?)?.toInt(),
        text: j['text'] as String? ?? '',
        dueLabel: j['due_label'] as String?,
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
