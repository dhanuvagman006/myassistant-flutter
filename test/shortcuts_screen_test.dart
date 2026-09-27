// Hub → Shortcuts (build 120): the list, Run with its one question, Delete,
// "Save as shortcut" for the last phone task, the service's plain lines,
// the sign-out reset, and the backend contract parsed here.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/models/shortcut.dart';
import 'package:myassistant/screens/shortcuts_screen.dart';
import 'package:myassistant/services/shortcut_runner.dart';
import 'package:myassistant/services/shortcuts_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'shortcut_runner_test.dart' show FakePorts;

final contract = jsonDecode(File('test/fixtures/shortcuts_contract.json').readAsStringSync())
    as Map<String, dynamic>;

class FakeServer {
  final calls = <String>[];
  final bodies = <Map<String, dynamic>?>[];
  List<Map<String, dynamic>> list = [contract['Shortcut'] as Map<String, dynamic>];
  bool ask = false;

  Future<ShortcutsReply> call(String method, String path, {Map<String, dynamic>? body}) async {
    calls.add('$method $path');
    bodies.add(body);
    if (method == 'GET') {
      return ShortcutsReply(200, {'ok': true, 'shortcuts': list, 'limits': {'max_shortcuts': 50}});
    }
    if (method == 'DELETE') {
      list = [];
      return const ShortcutsReply(200, {'ok': true});
    }
    if (path.endsWith('/run')) {
      return ShortcutsReply(200, ask
          ? contract['run_confirm'] as Map<String, dynamic>
          : {...contract['run_dispatched'] as Map<String, dynamic>, 'directive': contract['directive']});
    }
    if (path.endsWith('/approve')) {
      return ShortcutsReply(200, {...contract['run_dispatched'] as Map<String, dynamic>, 'directive': contract['directive']});
    }
    if (path.endsWith('/decline')) return const ShortcutsReply(200, {'ok': true, 'run': {'id': 32, 'status': 'cancelled'}});
    if (path == '/learn') return const ShortcutsReply(201, {'ok': true, 'shortcut': {}});
    if (method == 'PATCH') return const ShortcutsReply(409, {'ok': false, 'error': 'stale'});
    return const ShortcutsReply(404, {'ok': false, 'error': 'not_found'});
  }
}

void main() {
  late FakeServer server;
  late FakePorts ports;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ShortcutRunner.instance.reset();
    server = FakeServer();
    ports = FakePorts(background: true);
    ShortcutsService.transport = server.call;
    await ShortcutsService.instance.reset();
  });

  Future<void> open(WidgetTester tester, {({int runId, String goal})? task}) async {
    await tester.pumpWidget(MaterialApp(
        home: ShortcutsScreen(ports: ports, lastTask: ValueNotifier(task))));
    await tester.pumpAndSettle();
  }

  test('the contract: a shortcut, a directive and a confirm parse', () {
    final s = Shortcut.fromJson(contract['Shortcut'] as Map<String, dynamic>);
    expect(s.name, 'Office mode');
    expect(s.otherNames, ['ഓഫീസ് മോഡ്']);
    expect(s.steps.map((x) => x.cls), ['in_app', 'hand_back', 'stays']);
    final d = ShortcutRunDirective.fromJson(contract['directive'] as Map<String, dynamic>);
    expect(d.runId, 31);
    expect(d.steps[1].waitReturn, isTrue);
    expect(d.steps[0].action['action'], 'ringer_silent');
    expect((contract['run_confirm'] as Map)['run']['confirm']['summary'], contains('leaving now'));
  });

  testWidgets('a card shows the steps and how to say it; Run performs the steps', (tester) async {
    await open(tester);
    expect(find.text('Office mode'), findsOneWidget);
    expect(find.textContaining('Phone on silent · Chat message to Priya Shetty'), findsOneWidget);
    expect(find.text('Say “office mode”'), findsOneWidget);
    await tester.tap(find.byKey(const Key('run_7')));
    await tester.pumpAndSettle();
    expect(server.calls, contains('POST /7/run'));
    expect(ports.performed.first, 'phone_control:ringer_silent');
    expect(ports.performed[1], startsWith('open_url:whatsapp://'));
  });

  testWidgets('a step that sends something asks first: Not now runs nothing', (tester) async {
    server.ask = true;
    await open(tester);
    await tester.tap(find.byKey(const Key('run_7')));
    await tester.pumpAndSettle();
    expect(find.textContaining('leaving now'), findsOneWidget);
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(server.calls, contains('POST /runs/32/decline'));
    expect(ports.performed, isEmpty);
  });

  testWidgets('…and Yes, go ahead approves, then runs', (tester) async {
    server.ask = true;
    await open(tester);
    await tester.tap(find.byKey(const Key('run_7')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Yes, go ahead'));
    await tester.pumpAndSettle();
    expect(server.calls, contains('POST /runs/32/approve'));
    expect(ports.performed, isNotEmpty);
  });

  testWidgets('delete asks, then removes', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('menu_7')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete “Office mode”?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(server.calls, contains('DELETE /7'));
    expect(find.text('Office mode'), findsNothing);
  });

  testWidgets('the empty state says how to make one', (tester) async {
    server.list = [];
    await open(tester);
    expect(find.textContaining('No shortcuts yet'), findsOneWidget);
  });

  testWidgets('the last phone task can be saved, with a suggested name', (tester) async {
    await open(tester, task: (runId: 88, goal: 'add milk, bread and eggs to my grocery cart'));
    await tester.tap(find.byKey(const Key('save_task_as_shortcut')));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Milk bread eggs'), findsOneWidget);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(server.calls, contains('POST /learn'));
    expect(server.bodies[server.calls.indexOf('POST /learn')], {'run_id': 88, 'name': 'Milk bread eggs'});
    expect(find.byKey(const Key('save_task_as_shortcut')), findsNothing);
  });

  test('server codes become plain lines; a stale rename refreshes', () async {
    expect(ShortcutsService.lineFor('reserved_name'), contains('my own commands'));
    expect(ShortcutsService.lineFor('needs_detail', {'question': 'Who should the message go to?'}),
        'Who should the message go to?');
    expect(ShortcutsService.lineFor('whatever'), contains('try again'));
    await ShortcutsService.instance.refresh();
    final s = ShortcutsService.instance.shortcuts.single;
    final err = await ShortcutsService.instance.rename(s, 'Work mode');
    expect(err, contains('changed a moment ago'));
    expect(server.calls.where((c) => c == 'GET ').length, 2);
  });

  test('the saved list is cleared on sign-out', () async {
    await ShortcutsService.instance.refresh();
    await Future<void>.delayed(Duration.zero);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(ShortcutsService.cacheKey), isNotNull);
    await ShortcutsService.instance.reset();
    expect(prefs.getString(ShortcutsService.cacheKey), isNull);
    expect(ShortcutsService.instance.shortcuts, isEmpty);
  });

  test('suggested names come from the goal', () {
    expect(ShortcutsScreenNames.suggest('add milk, bread and eggs to my grocery cart'), 'Milk bread eggs');
    expect(ShortcutsScreenNames.suggest(''), '');
  });
}

