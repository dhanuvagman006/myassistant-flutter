import 'package:firebase_ai/firebase_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/ai/json_schema.dart';
import 'package:myassistant/ai/types.dart';

void main() {
  test('every scalar type, with descriptions', () {
    expect(schemaFromJson({'type': 'string', 'description': 'Who to call'}).toJson(),
        {'type': 'STRING', 'description': 'Who to call'});
    expect(schemaFromJson({'type': 'integer', 'minimum': 1, 'maximum': 10}).toJson(),
        {'type': 'INTEGER', 'minimum': 1.0, 'maximum': 10.0});
    expect(schemaFromJson({'type': 'number', 'format': 'double'}).toJson(),
        {'type': 'NUMBER', 'format': 'double'});
    expect(schemaFromJson({'type': 'boolean', 'title': 'Loud'}).toJson(),
        {'type': 'BOOLEAN', 'title': 'Loud'});
  });

  test('types in upper case (the server registry style) read the same', () {
    expect(schemaFromJson({'type': 'STRING'}).type, SchemaType.string);
    expect(schemaFromJson({'type': 'OBJECT', 'properties': {}}).type, SchemaType.object);
    expect(schemaFromJson({'type': 'Array', 'items': {'type': 'INTEGER'}}).items!.type,
        SchemaType.integer);
  });

  test('string enums; numeric choices go into the description', () {
    expect(
        schemaFromJson({
          'type': 'string',
          'enum': ['low', 'high'],
          'description': 'Volume',
        }).toJson(),
        {'type': 'STRING', 'format': 'enum', 'description': 'Volume', 'enum': ['low', 'high']});
    // No type but an enum: a string enum.
    expect(schemaFromJson({'enum': ['a', 'b']}).enumValues, ['a', 'b']);
    final n = schemaFromJson({'type': 'integer', 'enum': [5, 10], 'description': 'Minutes.'});
    expect(n.type, SchemaType.integer);
    expect(n.enumValues, isNull);
    expect(n.description, 'Minutes. One of: 5, 10.');
  });

  test('nullable, both ways of writing it', () {
    expect(schemaFromJson({'type': 'string', 'nullable': true}).nullable, isTrue);
    final s = schemaFromJson({'type': ['null', 'integer']});
    expect(s.type, SchemaType.integer);
    expect(s.nullable, isTrue);
    expect(schemaFromJson({'type': 'string'}).nullable, isNull);
  });

  test('objects: nested properties, required vs optional', () {
    final s = schemaFromJson({
      'type': 'object',
      'description': 'A contact',
      'properties': {
        'name': {'type': 'string'},
        'phone': {'type': 'string', 'description': 'E.164'},
        'tags': {
          'type': 'array',
          'items': {'type': 'string'},
          'minItems': 1,
          'maxItems': 3,
        },
        'address': {
          'type': 'object',
          'properties': {
            'city': {'type': 'string'},
          },
          'required': ['city'],
        },
      },
      'required': ['name'],
      'additionalProperties': false,
    });
    final j = s.toJson();
    expect(j['type'], 'OBJECT');
    expect(j['description'], 'A contact');
    expect(j['required'], ['name']);
    expect(j.containsKey('additionalProperties'), isFalse);
    final props = j['properties'] as Map;
    expect(props.keys, ['name', 'phone', 'tags', 'address']);
    expect(props['tags'], {
      'type': 'ARRAY',
      'items': {'type': 'STRING'},
      'minItems': 1,
      'maxItems': 3,
    });
    expect((props['address'] as Map)['required'], ['city']);
  });

  test('arrays without items get strings; unknown formats are dropped', () {
    expect(schemaFromJson({'type': 'array'}).items!.type, SchemaType.string);
    expect(schemaFromJson({'type': 'string', 'format': 'email'}).format, isNull);
    expect(schemaFromJson({'type': 'string', 'format': 'date-time'}).format, 'date-time');
    expect(schemaFromJson({'type': 'integer', 'format': 'int64'}).format, 'int64');
    expect(schemaFromJson(null).type, SchemaType.string);
  });

  test('a server tool becomes a FunctionDeclaration Gemini accepts', () {
    final d = declarationFor(const AiToolSpec(
      name: 'set_reminder',
      description: 'Sets a reminder.',
      parameters: {
        'type': 'object',
        'properties': {
          'text': {'type': 'string'},
          'at': {'type': 'string', 'format': 'date-time'},
          'repeat': {
            'type': 'string',
            'enum': ['none', 'daily'],
          },
        },
        'required': ['text', 'at'],
      },
    ));
    final j = d.toJson();
    expect(j['name'], 'set_reminder');
    expect(j['description'], 'Sets a reminder.');
    final params = j['parameters'] as Map;
    expect(params['type'], 'OBJECT');
    expect(params['required'], ['text', 'at']);
    expect((params['properties'] as Map)['repeat'],
        {'type': 'STRING', 'format': 'enum', 'enum': ['none', 'daily']});

    // A tool with no parameters: an empty object, as the server sends today.
    final none = declarationFor(const AiToolSpec(name: 'end_conversation')).toJson();
    expect(none['parameters'], {'type': 'OBJECT', 'properties': {}, 'required': []});
    expect(none['description'], '');
  });
}
