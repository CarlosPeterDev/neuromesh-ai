import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:neuromesh_ai/utils/output_links.dart';

void main() {
  test(
      'generated filenames with spaces, brackets, parentheses and Unicode remain usable',
      () {
    const name = 'flying car (blue) [1] 🌌.jpg';
    final uri = outputFileUri(name);
    expect(uri, isNot(contains(' ')));
    expect(uri, isNot(contains('(')));
    expect(outputFileName(uri.substring('nmfile:'.length)), name);
    final elements = md.Document()
        .parseInline('![Flying car]($uri)')
        .whereType<md.Element>();
    expect(elements.single.tag, 'img');
    expect(elements.single.attributes['src'], uri);
  });
  test(
      'old unescaped image links render and already escaped links are unchanged',
      () {
    const old = '![Flying car](nmfile:flying car.jpg)';
    final normalized = normalizeOutputLinks(old);
    expect(normalized, '![Flying car](nmfile:flying%20car.jpg)');
    expect(normalizeOutputLinks(normalized), normalized);
    expect(
        md.Document()
            .parseInline(normalized)
            .whereType<md.Element>()
            .single
            .attributes['src'],
        'nmfile:flying%20car.jpg');
  });
  test('literal percent signs survive exactly one decode', () {
    const name = '50% done.wav';
    expect(outputFileName(outputFileUri(name).substring(7)), name);
    expect(normalizeOutputLinks('[audio](${outputFileUri(name)})'),
        '[audio](${outputFileUri(name)})');
  });
  test('image discovery distinguishes previews from file attachments', () {
    final content =
        '![Car](${outputFileUri('flying car.jpg')}) [Audio](${outputFileUri('hello Carlos.wav')})';
    expect(outputFileNames(content), {'flying car.jpg', 'hello Carlos.wav'});
    expect(outputFileNames(content, imagesOnly: true), {'flying car.jpg'});
  });
}
