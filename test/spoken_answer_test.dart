import 'package:flutter_test/flutter_test.dart';
import 'package:neuromesh_ai/utils/spoken_answer.dart';

void main() {
  test('speech omits search sources, inline citations and bare URLs', () {
    expect(
      spokenAnswer('**A result** [2].\n\nSources:\n'
          '1. [Provider](https://example.com/source)\nhttps://example.net'),
      'A result.',
    );
    expect(spokenAnswer('Answer.\n\n### References\nA source'), 'Answer.');
  });
}
