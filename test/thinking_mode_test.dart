import 'package:flutter_test/flutter_test.dart';
import 'package:neuromesh_ai/utils/thinking_mode.dart';
import 'package:neuromesh_ai/utils/thought_parser.dart';

void main() {
  test('sends an Android template only when the model family supports it', () {
    expect(ThinkingMode.forModel('Qwen 3.5 Artemis').androidTemplate(false),
        'qwen3-direct');
    expect(ThinkingMode.forModel('Gemma-4-E2B-it').androidTemplate(true),
        'gemma4-thinking');
    expect(ThinkingMode.forModel('Gemma_4').androidTemplate(false), 'gemma4');
    expect(ThinkingMode.forModel('Gemma-3-4B'), ThinkingMode.unsupported);
    expect(ThinkingMode.forModel('DeepSeek R1'), ThinkingMode.unsupported);
  });

  test('separates Gemma thought channel markers from the chat answer', () {
    final thinking = splitThoughtTags('<|channel>thought\nCheck inputs');
    expect(thinking.isThinking, isTrue);
    expect(thinking.answer, isEmpty);
    final finished = splitThoughtTags(
        '<|channel>thought\nCheck inputs<channel|>Show answer');
    expect(finished.thought, 'Check inputs');
    expect(finished.answer, 'Show answer');
  });
}
