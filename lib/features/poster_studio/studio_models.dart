import 'dart:ui' show Size;

import 'studio_palettes.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  POSTER STUDIO (2026-09-30): "Make a poster for our event tomorrow".
///  The server writes the words and paints a picture WITHOUT any words in
///  it; the phone sets the words in its own fonts over that picture. A
///  model never draws a letter, so a name, a date or a venue is never
///  misspelt on the poster he shares.
/// ─────────────────────────────────────────────────────────────────────────

/// The lines of an event poster, each edited on its own.
enum StudioField { title, subtitle, date, time, location, cta, details }

extension StudioFieldText on StudioField {
  String get label => switch (this) {
        StudioField.title => 'Title',
        StudioField.subtitle => 'Subtitle',
        StudioField.date => 'Date',
        StudioField.time => 'Time',
        StudioField.location => 'Location',
        StudioField.cta => 'Button text',
        StudioField.details => 'Details',
      };

  String get hint => switch (this) {
        StudioField.title => 'Annual Day 2026',
        StudioField.subtitle => 'An evening of music and food',
        StudioField.date => 'Saturday, 4 October',
        StudioField.time => '7:00 PM',
        StudioField.location => 'Town Hall, MG Road',
        StudioField.cta => 'Register now',
        StudioField.details => 'Entry free · Call 98xxxxxx',
      };
}

/// The poster's shape: a feed post (4:5), a status / story (9:16) or a
/// square — the same sizes the server paints its backgrounds in.
enum StudioFormat { portrait, story, square }

extension StudioFormatSize on StudioFormat {
  Size get size => switch (this) {
        StudioFormat.portrait => const Size(1080, 1350),
        StudioFormat.story => const Size(1080, 1920),
        StudioFormat.square => const Size(1080, 1080),
      };

  String get label => switch (this) {
        StudioFormat.portrait => 'Post 4:5',
        StudioFormat.story => 'Status 9:16',
        StudioFormat.square => 'Square',
      };

  static StudioFormat fromWire(Object? v) => switch ('$v') {
        'story' => StudioFormat.story,
        'square' => StudioFormat.square,
        _ => StudioFormat.portrait,
      };
}

/// A background the server painted (`POST /posters/ai/background`), kept
/// as one of his documents.
class StudioBackground {
  const StudioBackground({
    required this.id,
    this.url = '',
    this.width = 0,
    this.height = 0,
    this.provider = '',
    this.mime = 'image/jpeg',
  });

  final String id;
  final String url;
  final int width;
  final int height;
  final String provider;
  final String mime;

  static StudioBackground? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = '${j['id'] ?? ''}'.trim();
    if (id.isEmpty || id == 'null') return null;
    int n(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? 0;
    return StudioBackground(
      id: id,
      url: '${j['url'] ?? ''}',
      width: n(j['width']),
      height: n(j['height']),
      provider: '${j['provider'] ?? ''}',
      mime: '${j['mime'] ?? 'image/jpeg'}',
    );
  }
}

/// The words and look the server's design proposed (`design` of
/// POST /posters/ai/design and of the `open_poster_studio` action). Every
/// field he did not say is empty and named in [missing]: the server never
/// invents a venue, a time, a price or a phone number.
class EventDesign {
  const EventDesign({
    this.title = '',
    this.subtitle = '',
    this.dateText = '',
    this.timeText = '',
    this.location = '',
    this.cta = '',
    this.details = const [],
    this.style = '',
    this.palette,
    this.backgroundPrompt = '',
    this.missing = const [],
    this.format = StudioFormat.portrait,
    this.date,
    this.source = 'ai',
  });

  final String title;
  final String subtitle;
  final String dateText;
  final String timeText;
  final String location;
  final String cta;
  final List<String> details;
  final String style;
  final StudioPalette? palette;
  final String backgroundPrompt;
  final List<String> missing;
  final StudioFormat format;

  /// 'YYYY-MM-DD', resolved in his time zone by the server.
  final String? date;

  /// 'ai' or 'fallback' (the model was down; only the facts code found).
  final String source;

  static String _s(Object? v) => v == null ? '' : '$v'.trim();

  factory EventDesign.fromJson(Map<String, dynamic> j) => EventDesign(
        title: _s(j['title']),
        subtitle: _s(j['subtitle']),
        dateText: _s(j['dateText']),
        timeText: _s(j['timeText']),
        location: _s(j['location']),
        cta: _s(j['cta']),
        details: [
          for (final d in (j['details'] is List ? j['details'] as List : const []))
            if (_s(d).isNotEmpty) _s(d),
        ],
        style: _s(j['style']),
        palette: StudioPalette.fromJson(j['palette']),
        backgroundPrompt: _s(j['backgroundPrompt']),
        missing: [
          for (final m in (j['missing'] is List ? j['missing'] as List : const []))
            if (_s(m).isNotEmpty) _s(m),
        ],
        format: StudioFormatSize.fromWire(j['format']),
        date: _s(j['date']).isEmpty ? null : _s(j['date']),
        source: _s(j['source']).isEmpty ? 'ai' : _s(j['source']),
      );

  Map<String, dynamic> toJson() => {
        'title': title,
        'subtitle': subtitle,
        'dateText': dateText,
        'timeText': timeText,
        'location': location,
        'cta': cta,
        'details': details,
        'style': style,
        if (palette != null) 'palette': palette!.toJson(),
        'backgroundPrompt': backgroundPrompt,
        'missing': missing,
        'format': format.name,
        'date': date,
        'source': source,
      };

  EventDesign copyWith({
    String? title,
    String? subtitle,
    String? dateText,
    String? timeText,
    String? location,
    String? cta,
    List<String>? details,
    String? style,
    StudioPalette? palette,
    String? backgroundPrompt,
    List<String>? missing,
    StudioFormat? format,
  }) =>
      EventDesign(
        title: title ?? this.title,
        subtitle: subtitle ?? this.subtitle,
        dateText: dateText ?? this.dateText,
        timeText: timeText ?? this.timeText,
        location: location ?? this.location,
        cta: cta ?? this.cta,
        details: details ?? this.details,
        style: style ?? this.style,
        palette: palette ?? this.palette,
        backgroundPrompt: backgroundPrompt ?? this.backgroundPrompt,
        missing: missing ?? this.missing,
        format: format ?? this.format,
        date: date,
        source: source,
      );

  /// One field's words (details one per line).
  String text(StudioField f) => switch (f) {
        StudioField.title => title,
        StudioField.subtitle => subtitle,
        StudioField.date => dateText,
        StudioField.time => timeText,
        StudioField.location => location,
        StudioField.cta => cta,
        StudioField.details => details.join('\n'),
      };

  /// His words for [f], exactly as typed (only the ends trimmed).
  EventDesign withText(StudioField f, String v) {
    final t = v.trim();
    return switch (f) {
      StudioField.title => copyWith(title: t),
      StudioField.subtitle => copyWith(subtitle: t),
      StudioField.date => copyWith(dateText: t),
      StudioField.time => copyWith(timeText: t),
      StudioField.location => copyWith(location: t),
      StudioField.cta => copyWith(cta: t),
      StudioField.details => copyWith(details: [
          for (final l in v.split('\n'))
            if (l.trim().isNotEmpty) l.trim(),
        ]),
    };
  }

  /// "Sat 4 Oct  ·  7:00 PM" — the date chip.
  String get when => [dateText, timeText].where((s) => s.trim().isNotEmpty).join('  ·  ');

  bool get isEmpty => title.isEmpty && subtitle.isEmpty && when.isEmpty && location.isEmpty;
}

/// A line the server could not fill because he did not say it — shown as
/// "Add location?" until he fills it or waves it away.
class StudioPrompt {
  const StudioPrompt(this.key, this.field, this.label);

  /// The server's own word for it ('location', 'price', 'phone' …).
  final String key;

  /// Where his answer goes: a line of its own, or one more detail line.
  final StudioField field;

  /// "Add location?"
  final String label;

  /// Prefix put before a detail-line answer ("Entry: ₹200").
  String get detailPrefix => switch (key) {
        'price' || 'fee' || 'entry' || 'ticket' => 'Entry: ',
        'phone' || 'contact' => 'Contact: ',
        'email' => '',
        'name' || 'host' || 'organiser' || 'organizer' => 'Hosted by ',
        'speaker' => 'Speaker: ',
        'registration' => 'Register: ',
        _ => '',
      };
}

StudioPrompt studioPromptFor(String missingKey) {
  final k = missingKey.trim().toLowerCase();
  return switch (k) {
    'location' || 'venue' || 'place' || 'address' => StudioPrompt(k, StudioField.location, 'Add location?'),
    // The server names its own fields (dateText, timeText); older words too.
    'time' || 'timetext' => StudioPrompt(k, StudioField.time, 'Add time?'),
    'date' || 'day' || 'datetext' => StudioPrompt(k, StudioField.date, 'Add date?'),
    'details' => StudioPrompt(k, StudioField.details, 'Add details?'),
    'speaker' => StudioPrompt(k, StudioField.details, 'Add speaker?'),
    'registration' => StudioPrompt(k, StudioField.details, 'Add how to register?'),
    'title' || 'event' => StudioPrompt(k, StudioField.title, 'Add a title?'),
    'subtitle' => StudioPrompt(k, StudioField.subtitle, 'Add a subtitle?'),
    'cta' => StudioPrompt(k, StudioField.cta, 'Add a button line?'),
    'price' || 'fee' || 'entry' || 'ticket' => StudioPrompt(k, StudioField.details, 'Add price?'),
    'phone' || 'contact' => StudioPrompt(k, StudioField.details, 'Add contact number?'),
    'email' => StudioPrompt(k, StudioField.details, 'Add email?'),
    'name' || 'host' || 'organiser' || 'organizer' =>
      StudioPrompt(k, StudioField.details, 'Add host name?'),
    _ => StudioPrompt(k, StudioField.details, 'Add ${k.replaceAll('_', ' ')}?'),
  };
}

/// The questions still open: a named line he has since filled is not
/// asked again, nor one he answered or waved away ([done]).
List<StudioPrompt> studioPrompts(EventDesign d, Set<String> done) {
  final out = <StudioPrompt>[];
  final seen = <String>{};
  for (final m in d.missing) {
    final p = studioPromptFor(m);
    if (done.contains(p.key) || !seen.add(p.label)) continue;
    if (p.field != StudioField.details && d.text(p.field).trim().isNotEmpty) continue;
    out.add(p);
  }
  return out;
}

/// What `open_poster_studio` carries (create_event_poster, build 135+).
class StudioDirective {
  const StudioDirective({
    this.request = '',
    this.design,
    this.backgroundId,
    this.background,
    this.backgroundJob,
  });

  final String request;
  final EventDesign? design;
  final String? backgroundId;
  final StudioBackground? background;

  /// Set when the background was still being painted: poll it.
  final String? backgroundJob;

  factory StudioDirective.fromJson(Map<String, dynamic> e) {
    String? s(Object? v) {
      final t = v == null ? '' : '$v'.trim();
      return t.isEmpty || t == 'null' ? null : t;
    }

    final bg = StudioBackground.fromJson(e['background']);
    final id = s(e['backgroundId']) ?? bg?.id;
    return StudioDirective(
      request: s(e['request']) ?? '',
      design: e['design'] is Map
          ? EventDesign.fromJson((e['design'] as Map).cast<String, dynamic>())
          : null,
      backgroundId: id,
      background: bg ?? (id == null ? null : StudioBackground(id: id)),
      // The id to poll (a {jobId} object is read too).
      backgroundJob: e['backgroundJob'] is Map
          ? s((e['backgroundJob'] as Map)['jobId'])
          : s(e['backgroundJob']),
    );
  }
}
