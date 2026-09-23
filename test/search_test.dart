// Search finds things by what they are, across every kind of item.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/models/client.dart';
import 'package:myassistant/models/reminder.dart';
import 'package:myassistant/models/user_document.dart';
import 'package:myassistant/screens/search_screen.dart';

UserDocument doc(int id, String title, {String summary = '', String note = ''}) =>
    UserDocument.fromJson({
      'id': id, 'filename': '$title.pdf', 'mime': 'application/pdf', 'title': title,
      'category': 'medical', 'docDate': '', 'summary': summary, 'note': note,
      'createdAt': 0,
    });

Client client(int id, String name, {String summary = ''}) => Client.fromJson({
      'id': id, 'name': name, 'kind': 'patient', 'phone': '', 'email': '',
      'summary': summary, 'tags': '', 'createdAt': 0, 'updatedAt': 0,
    });

void main() {
  final corpus = SearchCorpus(
    documents: [
      doc(1, 'Blood report', summary: 'Ramesh Kumar, HbA1c 7.2'),
      doc(2, 'Rent agreement', summary: 'Flat 4B, 11 months'),
      doc(3, 'Blood report', summary: 'Sita Devi, normal'),
    ],
    clients: [client(10, 'Ramesh Kumar', summary: '52M, type-2 diabetic')],
    reminders: const [Reminder(id: 20, text: 'Call Ramesh about the report', done: false)],
    chats: const [SearchChat('+919000000001', 'Ravi', 'Sent the proposal')],
  );

  test('every word must match — "ramesh report" is Ramesh\'s report', () {
    final r = searchCorpus(corpus, 'ramesh report');
    expect(r.documents.map((d) => d.id), [1]);
    expect(r.reminders.map((x) => x.id), [20]);
    expect(r.clients, isEmpty, reason: 'the client card says nothing about a report');
  });

  test('case does not matter, and it looks inside summaries', () {
    expect(searchCorpus(corpus, 'FLAT 4b').documents.map((d) => d.id), [2]);
    expect(searchCorpus(corpus, 'diabetic').clients.map((c) => c.id), [10]);
    expect(searchCorpus(corpus, 'proposal').chats.single.name, 'Ravi');
  });

  test('an empty query finds nothing rather than everything', () {
    expect(searchCorpus(corpus, '   ').isEmpty, isTrue);
  });

  testWidgets('results appear as you type, grouped by kind', (tester) async {
    await tester.pumpWidget(MaterialApp(home: SearchScreen(loader: () async => corpus)));
    await tester.pump();
    expect(find.textContaining('Search across 3 documents'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'ramesh');
    await tester.pump();
    expect(find.text('Documents · 1'), findsOneWidget);
    expect(find.text('Clients & patients · 1'), findsOneWidget);
    expect(find.text('Reminders · 1'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'xylophone');
    await tester.pump();
    expect(find.textContaining('Nothing matches'), findsOneWidget);
  });
}
