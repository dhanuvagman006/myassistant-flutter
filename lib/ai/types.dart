// Small value types shared by the lib/ai modules.
import 'dart:typed_data';

/// One line of conversation, as the server's memory and the model see it.
/// [role] is 'user' or 'model'.
class ChatTurn {
  const ChatTurn(this.role, this.text);

  final String role;
  final String text;

  bool get isUser => role != 'model';

  static ChatTurn? fromJson(Object? j) {
    if (j is! Map) return null;
    final text = j['text'];
    if (text is! String || text.trim().isEmpty) return null;
    final role = j['role'] == 'model' || j['role'] == 'assistant' ? 'model' : 'user';
    return ChatTurn(role, text);
  }

  Map<String, Object?> toJson() => {'role': role, 'text': text};

  @override
  bool operator ==(Object other) =>
      other is ChatTurn && other.role == role && other.text == text;

  @override
  int get hashCode => Object.hash(role, text);

  @override
  String toString() => '$role: $text';
}

/// Something the user attached to a turn: a photo, a PDF, a voice note, a
/// clip. [bytes] go to the cloud model; [path] is read into them when the
/// turn is sent.
class AiAttachment {
  const AiAttachment({
    required this.kind,
    required this.mimeType,
    this.bytes,
    this.path,
  });

  /// 'image' | 'pdf' | 'audio' | 'video'.
  final String kind;
  final String mimeType;
  final Uint8List? bytes;
  final String? path;

  bool get isImage => kind == 'image';

  /// What /ai/context is told about it (never the bytes).
  Map<String, String> toJson() => {'kind': kind, 'mime': mimeType};

  /// Kind from a MIME type: image/*, application/pdf, audio/*, video/*.
  static String kindOf(String mimeType) {
    final m = mimeType.toLowerCase();
    if (m.startsWith('image/')) return 'image';
    if (m.startsWith('audio/')) return 'audio';
    if (m.startsWith('video/')) return 'video';
    return 'pdf';
  }
}

/// A web page a grounded (Google Search) answer came from.
class SourceLink {
  const SourceLink({required this.uri, this.title});

  final String uri;
  final String? title;

  @override
  bool operator ==(Object other) => other is SourceLink && other.uri == uri;

  @override
  int get hashCode => uri.hashCode;

  @override
  String toString() => title == null ? uri : '$title <$uri>';
}

/// A tool the server offers this turn: its name, what it does and its
/// parameters as a JSON Schema object (converted in json_schema.dart).
class AiToolSpec {
  const AiToolSpec({
    required this.name,
    this.description = '',
    this.parameters = const {},
  });

  final String name;
  final String description;
  final Map<String, dynamic> parameters;

  static AiToolSpec? fromJson(Object? j) {
    if (j is! Map) return null;
    final name = j['name'];
    if (name is! String || name.isEmpty) return null;
    final params = j['parameters'];
    return AiToolSpec(
      name: name,
      description: j['description'] is String ? j['description'] as String : '',
      parameters: params is Map ? Map<String, dynamic>.from(params) : const {},
    );
  }
}
