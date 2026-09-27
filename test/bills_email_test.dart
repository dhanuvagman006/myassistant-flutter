// BILLS BY EMAIL (build 120) — the private address for forwarding bills.
//
// The models tolerate missing keys; documents carry where they came from;
// the screen is hidden until the server says the feature is on, then
// turns on, copies, switches off, gets a new address (with a confirm),
// shows every status, and offers "Set reminders" / "This was me" only
// where they apply; the voice tool's screen can be opened; and a tapped
// notification lands on the screen.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/features/assistant/state/assistant_engine.dart';
import 'package:myassistant/models/mail_inbox.dart';
import 'package:myassistant/models/user_document.dart';
import 'package:myassistant/screens/bills_email_screen.dart';
import 'package:myassistant/services/app_feedback.dart';
import 'package:myassistant/services/mail_inbox_service.dart';
import 'package:myassistant/shell/home_shell.dart';
import 'package:myassistant/widgets/document_tile.dart';

const _addr = '7k2m-q9xw-4tnp@in.example.test';

Map<String, dynamic> _item(int id, String status,
        {String auth = 'verified', bool verified = true, String? fromAddress, String? code,
        List<Map<String, dynamic>> reminders = const [], bool remindersDone = false, String reason = ''}) =>
    {
      'id': id,
      'receivedAt': 1790000000000,
      'subject': 'Subject $id',
      'from': 'biller.test',
      'auth': auth,
      'verified': verified,
      'fromAddress': fromAddress,
      'status': status,
      'reason': reason,
      'kind': 'bill',
      'documentIds': [id + 100],
      'reminders': reminders,
      'remindersDone': remindersDone,
      'skipped': const [],
      'confirmCode': code,
    };

/// A fake server behind the real service: records every call.
class _Server {
  bool available = true;
  Map<String, dynamic>? address;
  List<String> trusted = [];
  List<Map<String, dynamic>> items = [];
  final calls = <String>[];

  MailInboxService service() => MailInboxService(
        get: (p) async {
          calls.add('GET $p');
          if (p == '/mailin') {
            return {
              'available': available,
              'address': address,
              'trustedFrom': trusted,
              'limits': {'maxMb': 10, 'perDay': 25, 'maxFiles': 5},
            };
          }
          return {'messages': items};
        },
        post: (p, b) async {
          calls.add('POST $p $b');
          if (p == '/mailin/address') {
            address = {'address': _addr, 'status': 'active', 'createdAt': 1};
            return {'address': address};
          }
          if (p == '/mailin/address/state') {
            address = {...address!, 'status': (b as Map)['on'] == true ? 'active' : 'off'};
            return {'address': address};
          }
          if (p == '/mailin/address/rotate') {
            address = {'address': 'aaaa-bbbb-cccc@in.example.test', 'status': 'active'};
            return {'address': address, 'retired': _addr};
          }
          if (p == '/mailin/trusted/remove') {
            trusted = [];
            return {'trustedFrom': trusted};
          }
          if (p.endsWith('/trust')) {
            trusted = ['me@mail.test'];
            return {'trustedFrom': trusted, 'reminders': []};
          }
          return {'reminders': []};
        },
      );
}

Future<void> _pump(WidgetTester t, MailInboxService svc) async {
  await t.pumpWidget(MaterialApp(
    scaffoldMessengerKey: AppFeedback.messengerKey,
    home: BillsEmailScreen(service: svc),
  ));
  await t.pumpAndSettle();
}

void main() {
  tearDown(AppFeedback.resetForTest);

  group('models', () {
    test('MailItem and MailAddress parse, and survive missing keys', () {
      final m = MailItem.fromJson(_item(4, 'saved',
          reminders: [{'id': 9, 'text': 'Pay bill', 'atMs': 5}], code: '123456'));
      expect(m.id, 4);
      expect(m.reminders.single.text, 'Pay bill');
      expect(m.documentIds, [104]);
      expect(m.confirmCode, '123456');
      final bare = MailItem.fromJson({'id': 2});
      expect(bare.status, 'processing');
      expect(bare.auth, 'unverified');
      expect(bare.reminders, isEmpty);
      expect(MailItem.listFromJson(null), isEmpty);
      expect(MailAddress.fromJson({'address': _addr, 'status': 'off'})!.on, isFalse);
      expect(MailAddress.fromJson({}), isNull);
      final s = MailInboxState.fromJson({});
      expect(s.available, isFalse);
      expect(s.address, isNull);
      expect(s.perDay, 25);
    });

    test('UserDocument reads the source fields, and old payloads without them', () {
      final d = UserDocument.fromJson(
          {'id': 1, 'source': 'email', 'sourceLabel': 'biller.test', 'sourceVerified': true});
      expect(d.fromEmail, isTrue);
      expect(d.sourceLabel, 'biller.test');
      expect(d.sourceVerified, isTrue);
      final old = UserDocument.fromJson({'id': 1});
      expect(old.fromEmail, isFalse);
      expect(old.sourceVerified, isFalse);
    });
  });

  group('screen', () {
    testWidgets('not available: nothing to turn on', (t) async {
      final s = _Server()..available = false;
      await _pump(t, s.service());
      expect(find.text('Turn on'), findsNothing);
      expect(find.textContaining('not available'), findsOneWidget);
    });

    testWidgets('turn on → the address, which Copy puts on the clipboard', (t) async {
      final s = _Server();
      String? copied;
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (c) async {
        if (c.method == 'Clipboard.setData') copied = (c.arguments as Map)['text'] as String;
        return null;
      });
      addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await _pump(t, s.service());
      expect(find.text('Turn on'), findsOneWidget);
      await t.tap(find.text('Turn on'));
      await t.pumpAndSettle();
      expect(find.text(_addr), findsOneWidget);
      await t.tap(find.text('Copy'));
      await t.pumpAndSettle();
      expect(copied, _addr);
      await t.scrollUntilVisible(find.text('Nothing yet. Forward a bill to try it.'), 200,
          scrollable: find.byType(Scrollable).first);
      expect(find.text('Nothing yet. Forward a bill to try it.'), findsOneWidget);
    });

    testWidgets('the switch turns receiving off', (t) async {
      final s = _Server()..address = {'address': _addr, 'status': 'active'};
      await _pump(t, s.service());
      await t.tap(find.byKey(const ValueKey('bills-switch')));
      await t.pumpAndSettle();
      expect(s.calls, contains('POST /mailin/address/state {on: false}'));
      expect(find.textContaining('bounce back to the sender'), findsWidgets);
    });

    testWidgets('a new address asks first: Cancel keeps it, confirm replaces it', (t) async {
      final s = _Server()..address = {'address': _addr, 'status': 'active'};
      await _pump(t, s.service());
      await t.tap(find.text('Get a new address'));
      await t.pumpAndSettle();
      expect(find.text('Get a new address?'), findsOneWidget);
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(s.calls.where((c) => c.contains('rotate')), isEmpty);
      await t.tap(find.text('Get a new address'));
      await t.pumpAndSettle();
      await t.tap(find.text('Get new address'));
      await t.pumpAndSettle();
      expect(s.calls.where((c) => c.contains('rotate')).length, 1);
      expect(find.text('aaaa-bbbb-cccc@in.example.test'), findsOneWidget);
    });

    testWidgets('every status has its chip; the buttons appear only where they apply', (t) async {
      final s = _Server()
        ..address = {'address': _addr, 'status': 'active'}
        ..items = [
          _item(1, 'saved', reminders: [{'id': 1, 'text': 'Pay bill — due 5 Oct', 'atMs': 1}], remindersDone: true),
          _item(2, 'already_saved'),
          _item(3, 'not_saved', reason: 'looked like an ad'),
          _item(4, 'couldnt_read'),
          _item(5, 'confirm_code', code: '482913557'),
          _item(6, 'saved', auth: 'personal', verified: false, fromAddress: 'me@mail.test'),
          _item(7, 'saved', auth: 'unverified', verified: false),
        ];
      await _pump(t, s.service());
      final list = find.byType(Scrollable).first;
      Future<void> see(Finder f) async {
        await t.scrollUntilVisible(f, 200, scrollable: list);
        await t.ensureVisible(f);
        await t.pumpAndSettle();
      }
      await see(find.byKey(const ValueKey('bills-chip-1')));
      expect(find.text('Saved'), findsOneWidget);
      expect(find.textContaining('Pay bill — due 5 Oct'), findsOneWidget);
      await see(find.byKey(const ValueKey('bills-chip-3')));
      expect(find.text('Already saved'), findsOneWidget);
      expect(find.text('Not saved — looked like an ad'), findsOneWidget);
      await see(find.byKey(const ValueKey('bills-chip-5')));
      expect(find.text("Couldn't read"), findsOneWidget);
      expect(find.text('482913557'), findsOneWidget);
      await see(find.byKey(const ValueKey('bills-remind-7')));
      expect(find.text('Did you send this?'), findsOneWidget);
      expect(find.text('From me@mail.test'), findsOneWidget);
      expect(find.text('Sender not confirmed'), findsOneWidget);
      // "This was me" only on the personal row; "Set reminders" on both.
      expect(find.byKey(const ValueKey('bills-trust-6')), findsOneWidget);
      expect(find.byKey(const ValueKey('bills-trust-7')), findsNothing);
      expect(find.byKey(const ValueKey('bills-remind-1')), findsNothing);
      await t.tap(find.byKey(const ValueKey('bills-remind-7')));
      await t.pumpAndSettle();
      expect(s.calls, contains('POST /mailin/messages/7/remind {}'));
      await see(find.byKey(const ValueKey('bills-trust-6')));
      await t.tap(find.byKey(const ValueKey('bills-trust-6')));
      await t.pumpAndSettle();
      expect(s.calls, contains('POST /mailin/messages/6/trust {}'));
    });

    testWidgets('a trusted address is listed and Remove takes it off', (t) async {
      final s = _Server()
        ..address = {'address': _addr, 'status': 'active'}
        ..trusted = ['me@mail.test'];
      await _pump(t, s.service());
      expect(find.text('me@mail.test'), findsOneWidget);
      await t.tap(find.text('Remove'));
      await t.pumpAndSettle();
      expect(s.calls.where((c) => c.startsWith('POST /mailin/trusted/remove')).length, 1);
      expect(find.text('me@mail.test'), findsNothing);
    });

    testWidgets('no overflow at 320 dp and large text', (t) async {
      t.view.physicalSize = const Size(320, 640);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final s = _Server()
        ..address = {'address': _addr, 'status': 'off'}
        ..trusted = ['a.very.long.address.for.testing@mail.test']
        ..items = [_item(6, 'saved', auth: 'personal', verified: false, fromAddress: 'me@mail.test')];
      await t.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(size: Size(320, 640), textScaler: TextScaler.linear(1.6)),
          child: BillsEmailScreen(service: s.service()),
        ),
      ));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    });
  });

  group('documents', () {
    const email = UserDocument(
        id: 1, filename: 'bill.pdf', mime: 'application/pdf', title: 'Bill', category: 'bill',
        docDate: '', summary: '', note: '', createdAt: 0,
        source: 'email', sourceLabel: 'biller.test');
    const own = UserDocument(
        id: 2, filename: 'scan.jpg', mime: 'image/jpeg', title: 'Scan', category: 'other',
        docDate: '', summary: '', note: '', createdAt: 0);

    Future<void> grid(WidgetTester t, UserDocument d) => t.pumpWidget(MaterialApp(
          home: Scaffold(
            body: SizedBox(
                width: 180, height: 240, child: DocumentGridTile(document: d, onOpen: () {}, onLongPress: () {})),
          ),
        ));

    testWidgets('the email badge shows only on email documents', (t) async {
      await grid(t, email);
      expect(find.byIcon(Icons.mail_outline_rounded), findsOneWidget);
      await grid(t, own);
      expect(find.byIcon(Icons.mail_outline_rounded), findsNothing);
    });

    testWidgets('the actions sheet names the sending domain and warns when unconfirmed', (t) async {
      await t.pumpWidget(MaterialApp(
        home: Builder(
          builder: (ctx) => TextButton(
            onPressed: () => showDocumentActions(ctx, email, onOpen: () {}, onDelete: () {}),
            child: const Text('menu'),
          ),
        ),
      ));
      await t.tap(find.text('menu'));
      await t.pumpAndSettle();
      expect(find.text('From email · biller.test'), findsOneWidget);
      expect(find.text('Sender not confirmed — check it before paying.'), findsOneWidget);
    });
  });

  testWidgets('the voice tool can open the screen', (t) async {
    expect(AssistantEngine.instance.canOpenAppScreen('bills_email'), isTrue);
  });

  test("a tapped 'bills_email' notification opens Bills by email", () async {
    var opened = 0;
    await openNotificationPayload('bills_email', billsEmail: () async => opened++);
    expect(opened, 1);
  });
}
