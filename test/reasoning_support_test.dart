import 'package:flutter_test/flutter_test.dart';
import 'package:neuromesh_ai/utils/reasoning_support.dart';

void main() {
  test('reasoning uses runtime evidence regardless of model family', () {
    expect(ReasoningSupport.fromTemplates([]), ReasoningSupport.unknown);
    expect(ReasoningSupport.fromTemplates(['metadata-chat-supported']),
        ReasoningSupport.none);
    expect(ReasoningSupport.fromTemplates(['metadata-thinking-supported']),
        ReasoningSupport.toggleable);
    expect(ReasoningSupport.fromTemplates(['metadata-reasoning-always-on']),
        ReasoningSupport.alwaysOn);
    expect(ReasoningSupport.fromTemplates(['qwen', 'deepseek', 'gemma']),
        ReasoningSupport.unknown);
  });
}
