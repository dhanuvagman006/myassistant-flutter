// JSON SCHEMA -> firebase_ai Schema. The server describes each tool's
// parameters in JSON Schema (/ai/context "tools"); Gemini's function
// declarations take the OpenAPI subset firebase_ai's Schema models: object,
// string, integer, number, boolean, array, string enums, required
// properties, descriptions and nullable. Types may come lower- or upper-case
// (the server's registry upper-cases them for Gemini), a nullable value may
// be written `"type": ["string", "null"]` or `"nullable": true`, and
// anything Gemini would reject (unknown keywords, formats it does not
// know) is left out, as the server's own normalizeSchema does.
import 'package:firebase_ai/firebase_ai.dart';

import 'types.dart';

/// Formats Gemini accepts, per type. Others are dropped (only a hint).
const _formats = {
  'string': {'date-time', 'enum'},
  'integer': {'int32', 'int64'},
  'number': {'float', 'double'},
};

String? _text(Object? v) => v is String && v.trim().isNotEmpty ? v : null;

int? _int(Object? v) => v is num && v.isFinite ? v.toInt() : null;

double? _double(Object? v) => v is num && v.isFinite ? v.toDouble() : null;

/// One JSON Schema node as a firebase_ai [Schema].
Schema schemaFromJson(Object? node) {
  if (node is! Map) return Schema(SchemaType.string);
  var nullable = node['nullable'] == true;
  String? type;
  final t = node['type'];
  if (t is String) {
    type = t.toLowerCase();
  } else if (t is List) {
    final types = [for (final e in t) '$e'.toLowerCase()];
    if (types.contains('null')) nullable = true;
    type = types.firstWhere((e) => e != 'null', orElse: () => 'string');
  }
  final enumValues = node['enum'];
  type ??= node['properties'] is Map
      ? 'object'
      : node['items'] != null
          ? 'array'
          : 'string';
  final description = _text(node['description']);
  final title = _text(node['title']);
  final n = nullable ? true : null;
  final fmt = _text(node['format']);
  final format = fmt != null && (_formats[type]?.contains(fmt) ?? false) ? fmt : null;

  switch (type) {
    case 'object':
      final (properties, optional) = objectParts(node);
      return Schema(SchemaType.object,
          properties: properties,
          optionalProperties: optional,
          description: description,
          title: title,
          nullable: n);
    case 'array':
      return Schema(SchemaType.array,
          items: schemaFromJson(node['items'] ?? const {'type': 'string'}),
          minItems: _int(node['minItems']),
          maxItems: _int(node['maxItems']),
          description: description,
          title: title,
          nullable: n);
    case 'integer':
    case 'number':
      // Gemini's enums are strings only: numeric choices ride in the words.
      var words = description;
      if (enumValues is List && enumValues.isNotEmpty) {
        final choices = 'One of: ${enumValues.join(', ')}.';
        words = words == null ? choices : '$words $choices';
      }
      return Schema(type == 'integer' ? SchemaType.integer : SchemaType.number,
          format: format,
          minimum: _double(node['minimum']),
          maximum: _double(node['maximum']),
          description: words,
          title: title,
          nullable: n);
    case 'boolean':
      return Schema(SchemaType.boolean,
          description: description, title: title, nullable: n);
    default:
      if (enumValues is List && enumValues.isNotEmpty) {
        return Schema(SchemaType.string,
            enumValues: [for (final e in enumValues) '$e'],
            format: 'enum',
            description: description,
            title: title,
            nullable: n);
      }
      return Schema(SchemaType.string,
          format: format, description: description, title: title, nullable: n);
  }
}

/// An object node's properties, and which of them are NOT in `required`
/// (firebase_ai lists the optional ones and derives `required`).
(Map<String, Schema>, List<String>) objectParts(Object? node) {
  if (node is! Map) return (<String, Schema>{}, <String>[]);
  final required = node['required'] is List
      ? {for (final e in node['required'] as List) '$e'}
      : <String>{};
  final props = node['properties'];
  final out = <String, Schema>{};
  if (props is Map) {
    for (final e in props.entries) {
      out['${e.key}'] = schemaFromJson(e.value);
    }
  }
  return (out, [for (final k in out.keys) if (!required.contains(k)) k]);
}

/// A server tool as the function declaration Gemini is given.
FunctionDeclaration declarationFor(AiToolSpec tool) {
  final (properties, optional) = objectParts(tool.parameters);
  return FunctionDeclaration(tool.name, tool.description,
      parameters: properties, optionalParameters: optional);
}
