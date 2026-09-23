// The voice loop's event stream, parsed the way the server writes it.
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/core/network/assistant_api.dart';

void main() {
  late List<Map<String, dynamic>> events;
  late SseParser p;
  setUp(() {
    events = [];
    p = SseParser(events.add);
  });

  List<int?> feed(String raw) => raw.split('\n').map(p.line).toList();

  test('an event as the server writes it', () {
    final ids = feed('id: 7\ndata: {"type":"assistant_state","state":"thinking"}\n\n');
    expect(events, [
      {'type': 'assistant_state', 'state': 'thinking'}
    ]);
    expect(ids.whereType<int>(), [7], reason: 'Last-Event-ID replay depends on it');
  });

  test('a multi-line data field is one event, not a lost one', () {
    // The old parser kept only the last data line, so this was dropped.
    feed('data: {"type":"assistant_message",\ndata: "text":"two\\nlines"}\n\n');
    expect(events.single['text'], 'two\nlines');
  });

  test('heartbeats and comments are not events', () {
    feed(': hb\n\n: connected\n\n');
    expect(events, isEmpty);
  });

  test('a malformed event is skipped and the next one still arrives', () {
    feed('data: {not json\n\ndata: {"type":"ok"}\n\n');
    expect(events, [
      {'type': 'ok'}
    ]);
  });

  test('only one space after the colon is syntax', () {
    feed('data:{"type":"tight"}\n\n');
    expect(events.single['type'], 'tight');
  });
}
