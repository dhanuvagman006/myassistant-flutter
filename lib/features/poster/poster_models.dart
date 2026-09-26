// Grapheme clusters, so a name is spelled letter by letter as he sees it
// (flutter re-exports the characters package).
import 'package:flutter/widgets.dart' show StringCharacters;

/// ─────────────────────────────────────────────────────────────────────────
///  GIFT CARDS FROM HIS OWN PHOTO — the objects both sides agree on.
///
///  The client (2026-09-26): "make a birthday card for my daughter… with
///  my signature". The owner, the same day: "build it without AI… create
///  it like a GIFT CARD, not just a photo — a photo with some designs like
///  flowers or something, with 'Happy Birthday' and the caption or content
///  the user gives."
///
///  So the card is DRAWN, on the phone, from a spec the server keeps: his
///  exact words, a template, a colour, a size. Nothing here writes,
///  polishes or translates a word — the one thing an image model always
///  gets wrong on a card is the name.
///
///  Contract v2 (plan.contract, with the no-AI overrides of 2026-09-26;
///  v2 made the photo's colour part of the card — spec.photoColour — so
///  "black and white" is one undoable edit): REST JSON is camelCase; the
///  shared fixture is test/fixtures/poster_contract.json (the backend owns
///  the original at tests/fixtures/posters/contract.json and both suites
///  parse it).
/// ─────────────────────────────────────────────────────────────────────────

const posterOccasions = ['birthday', 'anniversary', 'wedding', 'festival', 'other'];
const posterLanguages = ['en', 'ml', 'hi', 'kn', 'ta', 'te'];
const posterColours = ['gold', 'pink', 'blue', 'green', 'white', 'purple'];

/// The gift-card designs, in the order the carousel shows them and "use
/// the other design" walks through (the server's DESIGN_IDS).
const posterDesigns = [
  'floral_blush',
  'golden_celebration',
  'balloons_confetti',
  'royal_mandala',
  'garden_green',
  'classic_ivory',
];

/// portrait 4:5 is what WhatsApp shows whole in a chat; story is 9:16 for
/// a WhatsApp status.
const posterFormats = ['portrait', 'story'];

/// 'enhanced' is the server's ffmpeg clean-up (levels, colour cast, fade,
/// gentle denoise and sharpening — no AI, 2026-09-26).
const posterPhotoUses = ['enhanced', 'original', 'none'];

/// Photo colour, applied by the server's clean-up: his photo as it is,
/// black and white, or old-photo brown. On a card it is spec.photoColour
/// (contract v2); a photo on its own keeps it as photo.colour.
const posterPhotoColours = ['keep', 'bw', 'sepia'];

/// The longest each line may be. Over it, NOTHING is cut: he is asked to
/// shorten it (the contract's `need`).
const posterLimits = <String, int>{
  'headline': 60,
  'name': 60,
  'message': 300,
  'from': 80,
  'date': 40,
  'forWhom': 40,
};

const textScaleMin = 0.8;
const textScaleMax = 1.6;
const textScaleStep = 0.15;

/// Pixel sizes of the exported PNG.
({int w, int h}) posterPixels(String format) =>
    format == 'story' ? (w: 1080, h: 1920) : (w: 1080, h: 1350);

T? _enum<T extends String>(Object? v, List<String> allowed) {
  final s = v?.toString();
  return s != null && allowed.contains(s) ? s as T : null;
}

String _str(Object? v) => v == null ? '' : v.toString();

double _num(Object? v, double fallback) =>
    v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? fallback;

/// Design ids arrive as 'floral_blush', 'floral' or 'Floral Blush' — the
/// first word decides, so a spoken or older spelling still lands.
String normalizeDesign(Object? v) {
  final s = _str(v).trim().toLowerCase();
  if (s.isEmpty) return '';
  if (posterDesigns.contains(s)) return s;
  final first = s.split(RegExp(r'[\s_\-&]+')).first;
  const byWord = {
    'floral': 'floral_blush',
    'flowers': 'floral_blush',
    'flower': 'floral_blush',
    'blush': 'floral_blush',
    'golden': 'golden_celebration',
    'gold': 'golden_celebration',
    'celebration': 'golden_celebration',
    'balloons': 'balloons_confetti',
    'balloon': 'balloons_confetti',
    'confetti': 'balloons_confetti',
    'royal': 'royal_mandala',
    'mandala': 'royal_mandala',
    'rangoli': 'royal_mandala',
    'garden': 'garden_green',
    'green': 'garden_green',
    'classic': 'classic_ivory',
    'ivory': 'classic_ivory',
  };
  return byWord[first] ?? '';
}

/// '4:5' / 'portrait' / 'square-ish' → portrait; '9:16' / 'story' /
/// 'status' → story.
String normalizeFormat(Object? v) {
  final s = _str(v).trim().toLowerCase();
  if (s == 'story' || s == '9:16' || s == 'status' || s == 'tall') return 'story';
  return 'portrait';
}

/// Where the photo sits inside its frame. x/y are the point of the photo
/// (0..1) kept at the frame's centre. zoom 1 is the default view: the
/// frame filled and no more — except a photo wider than its design's
/// frame, which zoom 1 shows WHOLE (so the family's end faces are never
/// cut by default); "closer" (up to 3, the contract's range) crops in.
class PhotoFocus {
  final double x;
  final double y;
  final double zoom;
  const PhotoFocus({this.x = 0.5, this.y = 0.5, this.zoom = 1});

  static const centre = PhotoFocus();

  bool get isDefault => x == 0.5 && y == 0.5 && zoom == 1;

  factory PhotoFocus.fromJson(Object? j) {
    if (j is! Map) return centre;
    return PhotoFocus(
      x: _num(j['x'], 0.5).clamp(0.0, 1.0),
      y: _num(j['y'], 0.5).clamp(0.0, 1.0),
      zoom: _num(j['zoom'], 1).clamp(1.0, 3.0),
    );
  }

  Map<String, dynamic> toJson() => {'x': x, 'y': y, 'zoom': zoom};

  PhotoFocus copyWith({double? x, double? y, double? zoom}) => PhotoFocus(
        x: (x ?? this.x).clamp(0.0, 1.0),
        y: (y ?? this.y).clamp(0.0, 1.0),
        zoom: (zoom ?? this.zoom).clamp(1.0, 3.0),
      );

  @override
  bool operator ==(Object other) =>
      other is PhotoFocus && other.x == x && other.y == y && other.zoom == zoom;

  @override
  int get hashCode => Object.hash(x, y, zoom);
}

/// The card, as words and choices. The server normalises it; the app draws
/// it exactly.
class PosterSpec {
  final int v;
  final String occasion;
  final String language;

  /// Who it is for, in his words ("my daughter"). Never printed.
  final String forWhom;
  final String headline;
  final bool headlineCustom;
  final String name;
  final int? age;
  final String message;
  final String from;
  final String date;

  /// True once he chose the language himself (else it follows his words).
  final bool languageCustom;
  final String colour;

  /// True once he named a colour; until then it follows the design.
  final bool colourCustom;
  final String design;
  final String format;
  final double textScale;
  final String photoUse;

  /// The photo's colours ON THIS CARD: 'keep' | 'bw' | 'sepia' (contract
  /// v2). The card draws GET /photos/:id/file?v=enhanced&colour=<this>.
  final String photoColour;
  final PhotoFocus photoFocus;
  final bool signature;

  const PosterSpec({
    this.v = 1,
    this.occasion = 'birthday',
    this.language = 'en',
    this.forWhom = '',
    this.headline = '',
    this.headlineCustom = false,
    this.name = '',
    this.age,
    this.message = '',
    this.from = '',
    this.date = '',
    this.languageCustom = false,
    this.colour = 'pink',
    this.colourCustom = false,
    this.design = 'floral_blush',
    this.format = 'portrait',
    this.textScale = 1.0,
    this.photoUse = 'none',
    this.photoColour = 'keep',
    this.photoFocus = PhotoFocus.centre,
    this.signature = false,
  });

  factory PosterSpec.fromJson(Map<String, dynamic> j) {
    final design = normalizeDesign(j['design'] ?? j['template']);
    final colour = resolveColour(j['colour'] ?? j['color']) ??
        designHomeColour[design] ??
        'pink';
    final occasion = _enum<String>(j['occasion'], posterOccasions) ?? 'birthday';
    final age = j['age'];
    return PosterSpec(
      v: (j['v'] as num?)?.toInt() ?? 1,
      occasion: occasion,
      language: _enum<String>(j['language'], posterLanguages) ?? 'en',
      forWhom: _str(j['forWhom']),
      headline: _str(j['headline']),
      headlineCustom: j['headlineCustom'] == true,
      name: _str(j['name']),
      age: age is num ? age.toInt() : int.tryParse(_str(age)),
      message: _str(j['message']),
      from: _str(j['from']),
      date: _str(j['date']),
      languageCustom: j['languageCustom'] == true,
      colour: colour,
      colourCustom: j['colourCustom'] == true,
      design: design.isEmpty ? 'floral_blush' : design,
      format: normalizeFormat(j['format'] ?? j['size']),
      textScale: _num(j['textScale'], 1.0).clamp(textScaleMin, textScaleMax),
      photoUse: _photoUse(j['photoUse']),
      // A card saved before v2 shows its photo in its own colours.
      photoColour: _enum<String>(j['photoColour'], posterPhotoColours) ?? 'keep',
      photoFocus: PhotoFocus.fromJson(j['photoFocus']),
      signature: j['signature'] == true,
    );
  }

  static String _photoUse(Object? v) {
    final s = _str(v);
    // The first plan called the ffmpeg clean-up 'gentle'; 'restored' (the
    // AI repair) is not switched on — both draw the cleaned-up photo.
    if (s == 'gentle' || s == 'restored') return 'enhanced';
    return posterPhotoUses.contains(s) ? s : 'none';
  }

  Map<String, dynamic> toJson() => {
        'v': v,
        'occasion': occasion,
        'language': language,
        'forWhom': forWhom,
        'headline': headline,
        'headlineCustom': headlineCustom,
        'name': name,
        'age': age,
        'message': message,
        'from': from,
        'date': date,
        'languageCustom': languageCustom,
        'colour': colour,
        'colourCustom': colourCustom,
        'design': design,
        'format': format,
        'textScale': textScale,
        'photoUse': photoUse,
        'photoColour': photoColour,
        'photoFocus': photoFocus.toJson(),
        'signature': signature,
      };

  /// The headline actually printed: his own when he dictated one, else the
  /// fixed table's (never a model's words). The server stores its automatic
  /// heading as text too ("Happy 25th Birthday"); that copy is NOT his, so
  /// it is worked out again here from the age, occasion and language — a
  /// card corrected to 26 must never go out saying 25th.
  String get printedHeadline {
    if (headlineCustom && headline.trim().isNotEmpty) return headline;
    return defaultHeadline(language: language, occasion: occasion, age: age);
  }

  PosterSpec copyWith({
    String? occasion,
    String? language,
    String? forWhom,
    String? headline,
    bool? headlineCustom,
    String? name,
    int? age,
    bool clearAge = false,
    String? message,
    String? from,
    String? date,
    bool? languageCustom,
    String? colour,
    bool? colourCustom,
    String? design,
    String? format,
    double? textScale,
    String? photoUse,
    String? photoColour,
    PhotoFocus? photoFocus,
    bool? signature,
  }) =>
      PosterSpec(
        v: v,
        occasion: occasion ?? this.occasion,
        language: language ?? this.language,
        forWhom: forWhom ?? this.forWhom,
        headline: headline ?? this.headline,
        headlineCustom: headlineCustom ?? this.headlineCustom,
        name: name ?? this.name,
        age: clearAge ? null : (age ?? this.age),
        message: message ?? this.message,
        from: from ?? this.from,
        date: date ?? this.date,
        languageCustom: languageCustom ?? this.languageCustom,
        colour: colour ?? this.colour,
        colourCustom: colourCustom ?? this.colourCustom,
        design: design ?? this.design,
        format: format ?? this.format,
        textScale: textScale ?? this.textScale,
        photoUse: photoUse ?? this.photoUse,
        photoColour: photoColour ?? this.photoColour,
        photoFocus: photoFocus ?? this.photoFocus,
        signature: signature ?? this.signature,
      );

  @override
  bool operator ==(Object other) =>
      other is PosterSpec && _mapEq(other.toJson(), toJson());

  @override
  int get hashCode => Object.hashAll(toJson().values.map((e) => '$e'));
}

bool _mapEq(Map<String, dynamic> a, Map<String, dynamic> b) {
  if (a.length != b.length) return false;
  for (final k in a.keys) {
    final x = a[k], y = b[k];
    if (x is Map<String, dynamic> && y is Map<String, dynamic>) {
      if (!_mapEq(x, y)) return false;
    } else if (x != y) {
      return false;
    }
  }
  return true;
}

/// A photo he gave for a card.
class PosterPhoto {
  final int id;
  final String source;
  final int width;
  final int height;
  final String colour;
  final String status;
  final String? reason;
  final String? message;
  final List<String> variants;
  final double? ssim;
  final String? provider;
  final int updatedAt;

  const PosterPhoto({
    required this.id,
    this.source = 'gallery',
    this.width = 0,
    this.height = 0,
    this.colour = 'keep',
    this.status = 'ready',
    this.reason,
    this.message,
    this.variants = const ['original'],
    this.ssim,
    this.provider,
    this.updatedAt = 0,
  });

  factory PosterPhoto.fromJson(Map<String, dynamic> j) => PosterPhoto(
        id: (j['id'] as num?)?.toInt() ?? 0,
        source: _str(j['source']).isEmpty ? 'gallery' : _str(j['source']),
        width: (j['width'] as num?)?.toInt() ?? 0,
        height: (j['height'] as num?)?.toInt() ?? 0,
        colour: _enum<String>(j['colour'], posterPhotoColours) ?? 'keep',
        status: _str(j['status']).isEmpty ? 'ready' : _str(j['status']),
        reason: j['reason'] as String?,
        message: j['message'] as String?,
        variants: [
          for (final v in (j['variants'] as List? ?? const ['original']))
            v.toString() == 'gentle' ? 'enhanced' : v.toString(),
        ],
        ssim: (j['ssim'] as num?)?.toDouble(),
        provider: j['provider'] as String?,
        updatedAt: (j['updatedAt'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'source': source,
        'width': width,
        'height': height,
        'colour': colour,
        'status': status,
        'reason': reason,
        'message': message,
        'variants': variants,
        'ssim': ssim,
        'provider': provider,
        'updatedAt': updatedAt,
      };

  double get aspect => width > 0 && height > 0 ? width / height : 0.75;

  /// The variant the card draws for [photoUse]: the one asked for when the
  /// server has it, else the original (a failed clean-up never loses his
  /// photo).
  String variantFor(String photoUse) {
    if (photoUse == 'none') return 'none';
    if (variants.contains(photoUse)) return photoUse;
    return 'original';
  }
}

/// One card, as the server keeps it.
class Poster {
  final int id;
  final String occasion;
  final int version;
  final PosterSpec spec;
  final PosterPhoto? photo;
  final int? finalDocumentId;

  /// The server still holds an earlier version to go back to.
  final bool canUndo;
  final int updatedAt;

  const Poster({
    required this.id,
    this.occasion = 'birthday',
    this.version = 1,
    required this.spec,
    this.photo,
    this.finalDocumentId,
    this.canUndo = false,
    this.updatedAt = 0,
  });

  /// A card that exists only on this phone (the server could not be
  /// reached). It still draws and shares; nothing is synced.
  bool get isLocal => id <= 0;

  factory Poster.fromJson(Map<String, dynamic> j) {
    final spec = PosterSpec.fromJson(
        (j['spec'] as Map?)?.cast<String, dynamic>() ?? const {});
    return Poster(
      id: (j['id'] as num?)?.toInt() ?? 0,
      occasion: _enum<String>(j['occasion'], posterOccasions) ?? spec.occasion,
      version: (j['version'] as num?)?.toInt() ?? 1,
      spec: spec,
      photo: j['photo'] is Map
          ? PosterPhoto.fromJson((j['photo'] as Map).cast<String, dynamic>())
          : null,
      finalDocumentId: (j['finalDocumentId'] as num?)?.toInt(),
      canUndo: j['canUndo'] == true,
      updatedAt: (j['updatedAt'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'occasion': occasion,
        'version': version,
        'spec': spec.toJson(),
        'photo': photo?.toJson(),
        'finalDocumentId': finalDocumentId,
        'canUndo': canUndo,
        'updatedAt': updatedAt,
      };

  Poster copyWith({
    int? id,
    int? version,
    PosterSpec? spec,
    PosterPhoto? photo,
    bool clearPhoto = false,
    int? finalDocumentId,
    bool? canUndo,
  }) =>
      Poster(
        id: id ?? this.id,
        occasion: spec?.occasion ?? occasion,
        version: version ?? this.version,
        spec: spec ?? this.spec,
        photo: clearPhoto ? null : (photo ?? this.photo),
        finalDocumentId: finalDocumentId ?? this.finalDocumentId,
        canUndo: canUndo ?? this.canUndo,
        updatedAt: updatedAt,
      );
}

/// Why a line could not be used as it is. 'too_long' comes from the
/// limits; 'no_room' from the card itself (the words do not fit even at
/// the smallest size the design allows). Either way he is ASKED to
/// shorten it — nothing is ever cut.
class PosterNeed {
  final String field;
  final String reason;
  final int? max;

  /// How long it is now, when the server counted it.
  final int? length;
  const PosterNeed({required this.field, required this.reason, this.max, this.length});

  factory PosterNeed.fromJson(Map<String, dynamic> j) => PosterNeed(
        field: _str(j['field']),
        reason: _str(j['reason']).isEmpty ? 'too_long' : _str(j['reason']),
        max: (j['max'] as num?)?.toInt(),
        length: (j['length'] as num?)?.toInt(),
      );

  Map<String, dynamic> toJson() => {
        'field': field,
        'reason': reason,
        if (max != null) 'max': max,
        if (length != null) 'length': length,
      };

  /// The field as he would say it.
  String get spoken => fieldLabel(field);

  @override
  bool operator ==(Object other) =>
      other is PosterNeed &&
      other.field == field &&
      other.reason == reason &&
      other.max == max;

  @override
  int get hashCode => Object.hash(field, reason, max);
}

String fieldLabel(String field) => switch (field) {
      'headline' => 'the heading',
      'name' => 'the name',
      'message' => 'the wishes',
      'from' => "the 'from' line",
      'age' => 'the age',
      'date' => 'the date',
      'forWhom' => 'who it is for',
      _ => field,
    };

/// One edit, as PATCH /posters/:id sends it.
class PosterChange {
  /// Lines to replace: headline, name, age, message, from, date.
  final Map<String, Object?> set;
  final String? textSize; // bigger | smaller | reset
  final String? colour;

  /// A design id, or 'next' ("use the other design").
  final String? design;
  final String? format;
  final String? photoUse;

  /// The card's photo colour (contract v2): 'keep' | 'bw' | 'sepia'.
  final String? photoColour;
  final PhotoFocus? photoFocus;
  final bool? signature;
  final int? photoId;
  final bool undo;

  const PosterChange({
    this.set = const {},
    this.textSize,
    this.colour,
    this.design,
    this.format,
    this.photoUse,
    this.photoColour,
    this.photoFocus,
    this.signature,
    this.photoId,
    this.undo = false,
  });

  static const undoChange = PosterChange(undo: true);

  bool get isEmpty =>
      set.isEmpty &&
      textSize == null &&
      colour == null &&
      design == null &&
      format == null &&
      photoUse == null &&
      photoColour == null &&
      photoFocus == null &&
      signature == null &&
      photoId == null &&
      !undo;

  factory PosterChange.fromJson(Map<String, dynamic> j) => PosterChange(
        set: (j['set'] as Map?)?.cast<String, Object?>() ?? const {},
        textSize: j['textSize'] as String?,
        colour: j['colour'] as String?,
        design: j['design'] as String?,
        format: j['format'] as String?,
        photoUse: j['photoUse'] as String?,
        photoColour: j['photoColour'] as String?,
        photoFocus:
            j['photoFocus'] == null ? null : PhotoFocus.fromJson(j['photoFocus']),
        signature: j['signature'] as bool?,
        photoId: (j['photoId'] as num?)?.toInt(),
        undo: j['undo'] == true,
      );

  Map<String, dynamic> toJson() => {
        if (set.isNotEmpty) 'set': set,
        if (textSize != null) 'textSize': textSize,
        if (colour != null) 'colour': colour,
        if (design != null) 'design': design,
        if (format != null) 'format': format,
        if (photoUse != null) 'photoUse': photoUse,
        if (photoColour != null) 'photoColour': photoColour,
        if (photoFocus != null) 'photoFocus': photoFocus!.toJson(),
        if (signature != null) 'signature': signature,
        if (photoId != null) 'photoId': photoId,
        if (undo) 'undo': true,
      };
}

/// The colour each design wears until he names one (the server's
/// designs[].defaultColour).
const designHomeColour = <String, String>{
  'floral_blush': 'pink',
  'golden_celebration': 'gold',
  'balloons_confetti': 'blue',
  'royal_mandala': 'purple',
  'garden_green': 'green',
  'classic_ivory': 'white',
};

/// The first design a card opens in, by occasion (server DEFAULT_DESIGN).
const designForOccasion = <String, String>{
  'birthday': 'floral_blush',
  'anniversary': 'golden_celebration',
  'wedding': 'royal_mandala',
  'festival': 'royal_mandala',
  'other': 'classic_ivory',
};

/// "Use the other design": the next one round the list.
String nextDesign(String now) =>
    posterDesigns[(posterDesigns.indexOf(now) + 1) % posterDesigns.length];

/// A colour word as he says it → one of the six. The same aliases the
/// server resolves (contract §1).
String? resolveColour(Object? word) {
  final w = _str(word).trim().toLowerCase();
  if (posterColours.contains(w)) return w;
  const aliases = {
    'red': 'pink',
    'rose': 'pink',
    'orange': 'gold',
    'yellow': 'gold',
    'cream': 'gold',
    'golden': 'gold',
    'navy': 'purple',
    'dark': 'purple',
    'night': 'purple',
    'violet': 'purple',
    'classic': 'white',
    'ivory': 'white',
    'sky': 'blue',
  };
  return aliases[w];
}

/// English ordinals: 1st 2nd 3rd 4th 11th 12th 13th 21st 22nd 101st 111th.
String ordinalEn(int n) {
  final h = n % 100;
  if (h >= 11 && h <= 13) return '${n}th';
  return switch (n % 10) {
    1 => '${n}st',
    2 => '${n}nd',
    3 => '${n}rd',
    _ => '${n}th',
  };
}

/// The fixed headline table (the contract fixture's `headlines`). Only
/// used when he did not dictate one; the server holds the same table and
/// its copy wins.
const posterHeadlines = <String, Map<String, String>>{
  'en': {
    'birthday': 'Happy Birthday',
    'anniversary': 'Happy Anniversary',
    'wedding': 'Happy Wedding Day',
    'festival': 'Warm Festive Wishes',
    'other': 'Best Wishes',
  },
  'ml': {
    'birthday': 'ജന്മദിനാശംസകൾ',
    'anniversary': 'വിവാഹ വാർഷിക ആശംസകൾ',
    'wedding': 'വിവാഹ ആശംസകൾ',
    'festival': 'ഉത്സവ ആശംസകൾ',
    'other': 'ആശംസകൾ',
  },
  'hi': {
    'birthday': 'जन्मदिन की शुभकामनाएँ',
    'anniversary': 'सालगिरह की शुभकामनाएँ',
    'wedding': 'विवाह की शुभकामनाएँ',
    'festival': 'त्योहार की शुभकामनाएँ',
    'other': 'शुभकामनाएँ',
  },
  'kn': {
    'birthday': 'ಹುಟ್ಟುಹಬ್ಬದ ಶುಭಾಶಯಗಳು',
    'anniversary': 'ವಿವಾಹ ವಾರ್ಷಿಕೋತ್ಸವದ ಶುಭಾಶಯಗಳು',
    'wedding': 'ವಿವಾಹದ ಶುಭಾಶಯಗಳು',
    'festival': 'ಹಬ್ಬದ ಶುಭಾಶಯಗಳು',
    'other': 'ಶುಭಾಶಯಗಳು',
  },
  'ta': {
    'birthday': 'பிறந்தநாள் வாழ்த்துகள்',
    'anniversary': 'திருமண நாள் வாழ்த்துகள்',
    'wedding': 'திருமண வாழ்த்துகள்',
    'festival': 'பண்டிகை வாழ்த்துகள்',
    'other': 'வாழ்த்துகள்',
  },
  'te': {
    'birthday': 'పుట్టినరోజు శుభాకాంక్షలు',
    'anniversary': 'పెళ్లి రోజు శుభాకాంక్షలు',
    'wedding': 'వివాహ శుభాకాంక్షలు',
    'festival': 'పండుగ శుభాకాంక్షలు',
    'other': 'శుభాకాంక్షలు',
  },
};

String defaultHeadline({
  required String language,
  required String occasion,
  int? age,
}) {
  final table = posterHeadlines[language] ?? posterHeadlines['en']!;
  final base = table[occasion] ?? table['birthday']!;
  if (language == 'en' && age != null && age > 0) {
    if (occasion == 'birthday') return 'Happy ${ordinalEn(age)} Birthday';
    if (occasion == 'anniversary') return 'Happy ${ordinalEn(age)} Anniversary';
  }
  return base;
}

/// The script a line uses for DRAWING it: any Indic letter gives the line
/// Indic metrics, so a Malayalam name inside English wishes keeps room for
/// its vowel signs. Not the card's language — that is [writtenLanguage].
String scriptOf(String text) {
  if (RegExp(r'[ഀ-ൿ]').hasMatch(text)) return 'ml';
  if (RegExp(r'[ऀ-ॿ]').hasMatch(text)) return 'hi';
  if (RegExp(r'[ಀ-೿]').hasMatch(text)) return 'kn';
  if (RegExp(r'[஀-௿]').hasMatch(text)) return 'ta';
  if (RegExp(r'[ఀ-౿]').hasMatch(text)) return 'te';
  return 'en';
}

final _latinLetter = RegExp(r'\p{Script=Latin}', unicode: true);
final _indicLetters = <(String, RegExp)>[
  ('ml', RegExp(r'\p{Script=Malayalam}', unicode: true)),
  ('hi', RegExp(r'\p{Script=Devanagari}', unicode: true)),
  ('kn', RegExp(r'\p{Script=Kannada}', unicode: true)),
  ('ta', RegExp(r'\p{Script=Tamil}', unicode: true)),
  ('te', RegExp(r'\p{Script=Telugu}', unicode: true)),
];

/// The language a text is WRITTEN in, letter by letter, exactly as the
/// server's scriptOf counts it: most letters win (a tie goes to English),
/// so "Happy birthday അഞ്ജലി" stays an English card with a Malayalam name.
/// null when it has no letters. Mirrored so the heading shown before the
/// server answers — and on a card made offline — is the heading the server
/// will print (integration check, 2026-09-26: "any Malayalam letter wins"
/// here had the card flip languages a second after each edit).
String? writtenLanguage(String text) {
  final counts = <String, int>{'en': 0, 'ml': 0, 'hi': 0, 'kn': 0, 'ta': 0, 'te': 0};
  for (final r in text.runes) {
    final ch = String.fromCharCode(r);
    if (_latinLetter.hasMatch(ch)) {
      counts['en'] = counts['en']! + 1;
      continue;
    }
    for (final (lang, rx) in _indicLetters) {
      if (rx.hasMatch(ch)) {
        counts[lang] = counts[lang]! + 1;
        break;
      }
    }
  }
  String? best;
  var bestN = 0;
  counts.forEach((lang, n) {
    if (n > bestN) {
      best = lang;
      bestN = n;
    }
  });
  return best;
}

/// The card's language when nobody named one: its wishes, else its name,
/// else English (the server's detectLanguage).
String posterLanguageOf(PosterSpec s) =>
    writtenLanguage(s.message) ?? writtenLanguage(s.name) ?? 'en';

/// 'Ananya' → 'A-N-A-N-Y-A', read back so a misheard name is caught
/// before it is shared. Latin names only; null for any other script.
String? spellName(String name) {
  final n = name.trim();
  if (n.isEmpty) return null;
  if (!RegExp(r"^[A-Za-z .'’\-]+$").hasMatch(n)) return null;
  return n
      .split(RegExp(r'\s+'))
      .map((w) => w
          .characters
          .where((c) => RegExp(r'[A-Za-z]').hasMatch(c))
          .map((c) => c.toUpperCase())
          .join('-'))
      .where((w) => w.isNotEmpty)
      .join(' ');
}

/// The age as a numeral beside a non-English heading (the table's
/// headings carry no ordinal); null when it is not printed.
String? ageLine(PosterSpec s) =>
    s.language != 'en' &&
            s.age != null &&
            s.age! > 0 &&
            (s.occasion == 'birthday' || s.occasion == 'anniversary')
        ? '${s.age}'
        : null;

/// The words exactly as printed, top to bottom — the read-back, and the
/// server's words(spec) (the fixture's examples.words).
List<String> printedWords(PosterSpec s) => [
      s.printedHeadline,
      ageLine(s) ?? '',
      s.name,
      ...s.message.split('\n'),
      s.from,
      s.date,
    ].map((x) => x.trim()).where((x) => x.isNotEmpty).toList();

/// The contract's only text clean-up (the server's cleanText): trim,
/// collapse runs of spaces, keep at most four line breaks in the wishes —
/// breaks past the fourth become spaces, so every word stays. No
/// re-casing, no spelling, no translation.
String cleanLine(String field, String raw) {
  var s = raw.replaceAll(RegExp(r'\r\n?'), '\n');
  s = s.replaceAll(RegExp(r'[^\S\n]+'), ' ');
  if (field != 'message') {
    return s.replaceAll(RegExp(r'\s*\n\s*'), ' ').trim();
  }
  final lines = s.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
  if (lines.length > 5) {
    return [...lines.take(4), lines.skip(4).join(' ')].join('\n');
  }
  return lines.join('\n');
}

/// How long a line is against [posterLimits]: in code points, exactly as
/// the server counts it (spec.js lengthOf; the fixture's error_need
/// `length`). Counted as graphemes here, a Malayalam line the phone passed
/// came back from the server as "too long" and was taken off the card — or,
/// on a card made offline, failed its create and was blamed on the photo
/// (integration check, 2026-09-26). Code points are the one count both
/// sides agree on whatever their Unicode versions.
int posterTextLength(String text) => text.runes.length;

/// Lines over their limit, as `need`s (counted as the server counts).
List<PosterNeed> checkLimits(Map<String, Object?> set) => [
      for (final e in set.entries)
        if (e.value is String &&
            posterLimits.containsKey(e.key) &&
            posterTextLength(e.value as String) > posterLimits[e.key]!)
          PosterNeed(
            field: e.key,
            reason: 'too_long',
            max: posterLimits[e.key],
            length: posterTextLength(e.value as String),
          ),
    ];

/// The next text size after "bigger"/"smaller"; null when already at the
/// end (the voice tool then says so honestly).
double? nextTextScale(double now, String dir) {
  if (dir == 'reset') return 1.0;
  final next = dir == 'bigger' ? now + textScaleStep : now - textScaleStep;
  final clamped = next.clamp(textScaleMin, textScaleMax);
  final rounded = (clamped * 100).roundToDouble() / 100;
  return (rounded - now).abs() < 0.001 ? null : rounded;
}

/// Applies [c] to [s] the way the server does, for the instant preview
/// (the server's answer then replaces it) and for a card kept only on this
/// phone. Returns the needs instead when a line is over its limit.
({PosterSpec? spec, List<PosterNeed> needs}) applyChange(PosterSpec s, PosterChange c) {
  final cleaned = <String, Object?>{
    for (final e in c.set.entries)
      e.key: e.value is String ? cleanLine(e.key, e.value as String) : e.value,
  };
  final needs = checkLimits(cleaned);
  if (needs.isNotEmpty) return (spec: null, needs: needs);
  var out = s;
  if (cleaned.isNotEmpty) {
    final age = cleaned['age'];
    out = out.copyWith(
      headline: cleaned['headline'] as String?,
      headlineCustom: cleaned.containsKey('headline')
          ? (cleaned['headline'] as String).trim().isNotEmpty
          : null,
      name: cleaned['name'] as String?,
      message: cleaned['message'] as String?,
      from: cleaned['from'] as String?,
      date: cleaned['date'] as String?,
      age: age is num ? age.toInt() : null,
      clearAge: cleaned.containsKey('age') && age == null,
    );
    // A fresh name or wishes in another script moves the card's language
    // with them, as the server does, unless a language was named.
    if (!out.languageCustom &&
        (cleaned.containsKey('name') || cleaned.containsKey('message'))) {
      final lang = posterLanguageOf(out);
      if (lang != out.language) out = out.copyWith(language: lang);
    }
  }
  if (c.textSize != null) {
    final n = nextTextScale(out.textScale, c.textSize!);
    if (n != null) out = out.copyWith(textScale: n);
  }
  if (c.design != null) {
    final d = c.design == 'next' ? nextDesign(out.design) : normalizeDesign(c.design);
    if (d.isNotEmpty) {
      out = out.copyWith(design: d);
      // The colour follows the design until he names one.
      if (!out.colourCustom) out = out.copyWith(colour: designHomeColour[d]);
    }
  }
  if (c.colour != null) {
    final col = resolveColour(c.colour);
    if (col != null) out = out.copyWith(colour: col, colourCustom: true);
  }
  if (c.format != null) out = out.copyWith(format: normalizeFormat(c.format));
  if (c.photoUse != null && posterPhotoUses.contains(c.photoUse)) {
    out = out.copyWith(photoUse: c.photoUse);
  }
  if (c.photoColour != null && posterPhotoColours.contains(c.photoColour)) {
    out = out.copyWith(photoColour: c.photoColour);
  }
  if (c.photoFocus != null) out = out.copyWith(photoFocus: c.photoFocus);
  if (c.signature != null) out = out.copyWith(signature: c.signature);
  // The heading follows the age, occasion and language until he dictates
  // one — worked out again after every change, as the server's normalize
  // does, so "she is turning 26" moves "25th" to "26th" at once.
  if (!out.headlineCustom) {
    out = out.copyWith(
        headline: defaultHeadline(language: out.language, occasion: out.occasion, age: out.age));
  }
  return (spec: out, needs: const []);
}

/// What the assistant still has to ask for, in the server's order.
List<String> missingLines(PosterSpec s) => [
      if (s.name.trim().isEmpty) 'name',
      if (s.age == null && (s.occasion == 'birthday' || s.occasion == 'anniversary')) 'age',
      if (s.message.trim().isEmpty) 'message',
      if (s.from.trim().isEmpty) 'from',
    ];
