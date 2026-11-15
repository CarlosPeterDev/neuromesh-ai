import 'package:flutter_test/flutter_test.dart';
import 'package:neuromesh_ai/utils/llama_archs.dart';
import 'package:neuromesh_ai/utils/page_text.dart';

void main() {
  test('readableText keeps article paragraphs and drops chrome', () {
    final html = '''
<html><body><nav><p>Home About Contact us today please</p></nav>
<article><h1>Moon landing</h1>
<p>Apollo 11 landed on the Moon on July 20, 1969, carrying Neil Armstrong and Buzz Aldrin.</p>
<p>Michael Collins stayed in lunar orbit aboard the command module Columbia throughout.</p>
<script>var x = "tracking";</script>
${'<p>Filler sentence about nothing in particular here. </p>' * 12}
</article><footer><p>Copyright notice and other footer text goes here</p></footer></body></html>''';
    final t = readableText(html);
    expect(t, contains('Apollo 11 landed'));
    expect(t, contains('Moon landing'));
    expect(t, isNot(contains('tracking')));
    expect(t, isNot(contains('Copyright')));
    expect(t, isNot(contains('Home About')));
  });

  test('bestPassages picks the matching passage', () {
    final text = [
      'Bananas are rich in potassium and grow in tropical climates around the world today.',
      'The capital of France is Paris, a city on the Seine known for the Louvre museum.',
      'Football is played with eleven players per side on a rectangular grass pitch always.',
    ].join('\n\n');
    final r = bestPassages(text, 'capital of France', maxChars: 120);
    expect(r, contains('Paris'));
  });

  test('searchQuery strips filler and borrows context for follow-ups', () {
    expect(searchQuery('Please search for the weather in Cairo?'),
        'the weather in Cairo');
    expect(searchQuery('and in 2025?', previous: 'Who won the Nile cup'),
        'Who won the Nile cup and in 2025');
  });

  test('dedupeByHost keeps one result per site', () {
    final r = dedupeByHost([
      'https://www.a.com/1',
      'https://a.com/2',
      'https://b.com/x',
    ], (s) => s);
    expect(r, ['https://www.a.com/1', 'https://b.com/x']);
  });

  test('architecture support', () {
    expect(isSupportedLlamaArch('llama'), isTrue);
    expect(isSupportedLlamaArch('qwen3'), isTrue);
    expect(isSupportedLlamaArch(null), isTrue);
    expect(isSupportedLlamaArch('bert'), isFalse);
    expect(isSupportedLlamaArch('some-future-arch'), isFalse);
  });
}
