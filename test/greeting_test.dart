import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/features/assistant/state/assistant_engine.dart';

void main() {
  test('the orb greets the owner the respectful Indian way', () {
    expect(AssistantEngine.orbGreeting(name: 'Dhanush K', gender: 'male'),
        'Hello Sir!');
    expect(AssistantEngine.orbGreeting(name: 'Asha', gender: 'female'),
        "Hello Ma'am!");
  });

  test('an unknown gender is never guessed — "<name> ji" instead', () {
    expect(AssistantEngine.orbGreeting(name: 'Ravi Kumar', gender: null),
        'Hello Ravi ji!');
    expect(AssistantEngine.orbGreeting(name: 'Ravi', gender: 'other'),
        'Hello Ravi ji!');
    expect(AssistantEngine.orbGreeting(), 'Hello!');
  });

  test('never the bare first name', () {
    final g = AssistantEngine.greetingFor('Dhanush',
        gender: 'male', now: DateTime(2026, 9, 23, 16));
    expect(g, 'Good afternoon, Sir! How can I help you today?');
    expect(g.contains('Dhanush'), isFalse);
  });
}
