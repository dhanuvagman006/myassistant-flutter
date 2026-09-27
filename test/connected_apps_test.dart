// CONNECTED APPS (build 120) — the Notion card.
//
// Pins: every status parses; a closed browser tab still reloads and reports
// "connected" when the server says the link was made; the card hides when
// the server does not offer Notion; Disconnect sends the DELETE only after
// the user confirms; the Hub and the voice command reach the screen.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/features/assistant/state/assistant_engine.dart';
import 'package:myassistant/screens/connected_apps_screen.dart';
import 'package:myassistant/screens/hub_screen.dart';
import 'package:myassistant/services/connections_service.dart';
import 'package:myassistant/services/privacy_prefs_service.dart' show apiTransport;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late List<(String, String)> calls;
  late String status;
  late bool available;

  Map<String, dynamic> card() => {
        'connections': [
          {
            'id': 'notion', 'name': 'Notion', 'available': available, 'status': status,
            'workspace': status == 'not_connected' ? null : "Asha's Notion", 'minBuild': 120,
          },
        ],
      };

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    calls = [];
    status = 'not_connected';
    available = true;
    ConnectionsService.instance.resetForTest();
    ConnectionsService.transport = (method, path, [body]) async {
      calls.add((method, path));
      if (path == '/connections') return card();
      if (path == '/connections/notion/start') {
        return {
          'authUrl': 'https://api.notion.com/v1/oauth/authorize?state=x',
          'callbackScheme': 'com.myassistant.myassistant',
        };
      }
      if (method == 'DELETE') {
        status = 'not_connected';
        return {'ok': true};
      }
      return {'connected': false};
    };
  });
  tearDown(() {
    ConnectionsService.transport = apiTransport;
  });

  test('each status parses; nothing unknown is taken for connected', () {
    for (final s in ['not_connected', 'connected', 'needs_reconnect']) {
      expect(ConnectionInfo.fromJson({'id': 'notion', 'status': s}).status, s);
    }
    final odd = ConnectionInfo.fromJson({'id': 'notion', 'status': 'weird', 'available': true});
    expect(odd.status, 'not_connected');
    expect(odd.connected, isFalse);
  });

  test('connect: the result word from the redirect; the list is reloaded', () async {
    ConnectionsService.webAuth = (url, scheme) async {
      expect(scheme, 'com.myassistant.myassistant');
      status = 'connected';
      return 'com.myassistant.myassistant://connected?app=notion&result=ok';
    };
    expect(await ConnectionsService.instance.connectNotion(), ConnectResult.connected);
    expect(ConnectionsService.instance.notion!.workspace, "Asha's Notion");
  });

  test('a closed tab still reloads — and says connected if the link was made', () async {
    ConnectionsService.webAuth = (url, scheme) async {
      status = 'connected'; // the exchange finished before the tab closed
      throw PlatformException(code: 'CANCELED');
    };
    expect(await ConnectionsService.instance.connectNotion(), ConnectResult.connected);
    ConnectionsService.webAuth = (url, scheme) async => throw PlatformException(code: 'CANCELED');
    status = 'not_connected';
    expect(await ConnectionsService.instance.connectNotion(), ConnectResult.cancelled);
    expect(calls.where((c) => c.$2 == '/connections').length, greaterThanOrEqualTo(2));
  });

  testWidgets('the card follows the server; hidden when Notion is not offered', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ConnectedAppsScreen()));
    await tester.pumpAndSettle();
    expect(find.text('Notion'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);

    available = false;
    await tester.pumpWidget(const SizedBox());
    ConnectionsService.instance.resetForTest();
    await tester.pumpWidget(const MaterialApp(home: ConnectedAppsScreen()));
    await tester.pumpAndSettle();
    expect(find.text('Notion'), findsNothing);
    expect(find.text('Email'), findsOneWidget);
  });

  testWidgets('needs a reconnect: says so, and offers Reconnect', (tester) async {
    status = 'needs_reconnect';
    await tester.pumpWidget(const MaterialApp(home: ConnectedAppsScreen()));
    await tester.pumpAndSettle();
    expect(find.text('Needs a quick reconnect'), findsOneWidget);
    expect(find.text('Reconnect'), findsOneWidget);
  });

  testWidgets('Disconnect asks first; only "Disconnect" sends the DELETE', (tester) async {
    status = 'connected';
    await tester.pumpWidget(const MaterialApp(home: ConnectedAppsScreen()));
    await tester.pumpAndSettle();
    expect(find.text("Connected to Asha's Notion"), findsOneWidget);
    await tester.tap(find.text('Disconnect'));
    await tester.pumpAndSettle();
    expect(find.text('Disconnect Notion?'), findsOneWidget);
    await tester.tap(find.text('Keep it'));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.$1 == 'DELETE'), isEmpty);
    await tester.tap(find.text('Disconnect'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Disconnect'));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.$1 == 'DELETE' && c.$2 == '/connections/notion').length, 1);
    expect(find.text('Connect'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('the Hub has the entry, without a company name', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: HubScreen())));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Connected apps'), 300);
    expect(find.text('Connected apps'), findsOneWidget);
    expect(File('lib/screens/hub_screen.dart').readAsStringSync(), isNot(contains('Notion')));
  });

  testWidgets('"open connected apps" is a screen the assistant can open', (t) async {
    expect(AssistantEngine.instance.canOpenAppScreen('connected_apps'), isTrue);
  });
}
