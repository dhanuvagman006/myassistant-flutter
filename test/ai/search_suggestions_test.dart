import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/ai/search_suggestions.dart';

// Google's renderedContent, shaped as the Gemini API sends it.
const _rendered = '''
<style>.container { align-items: center; } .chip { display: inline-block; }</style>
<div class="container">
  <div class="headline"><svg class="logo-light" width="18" height="18"></svg></div>
  <div class="carousel">
    <a class="chip" href="https://www.google.com/search?q=who+won+the+match&amp;client=app-vertex-grounding&amp;safesearch=active">who won the match</a>
    <a href='https://www.google.com/search?q=india+score' class="chip big">india <b>score</b></a>
    <a class="chip" href="https://www.google.com/search?q=who+won+the+match&amp;client=app-vertex-grounding&amp;safesearch=active">who won the match</a>
    <a class="logo" href="https://www.google.com">Google</a>
    <a class="chip" href="javascript:alert(1)">bad</a>
  </div>
</div>
''';

void main() {
  test('the chips, in order, with their Google links (entities decoded)', () {
    final chips = parseSearchSuggestions(_rendered);
    expect(chips, const [
      SearchSuggestion(
        label: 'who won the match',
        url: 'https://www.google.com/search?q=who+won+the+match&client=app-vertex-grounding&safesearch=active',
      ),
      SearchSuggestion(label: 'india score', url: 'https://www.google.com/search?q=india+score'),
    ]);
  });

  test('nothing to show', () {
    expect(parseSearchSuggestions(null), isEmpty);
    expect(parseSearchSuggestions(''), isEmpty);
    expect(parseSearchSuggestions('<div>no chips here</div>'), isEmpty);
  });
}
