import 'package:flutter_test/flutter_test.dart';
import 'package:neuromesh_ai/services/chat_tool_service.dart';
import 'package:neuromesh_ai/services/chat_calculator.dart';

void main() {
  group('local chat context fitting', () {
    test('preserves short voice and ordinary requests under context pressure',
        () {
      for (final prompt in [
        'Create audio file that says hello Carlos using tts tool',
        'Can you explain it?',
        'Create a file in the workspace named hello.txt',
        '',
      ]) {
        final history = [
          {'role': 'assistant', 'content': 'old answer ' * 200},
          {'role': 'user', 'content': prompt},
        ];
        expect(
            ChatToolService.fitToContext(
                'instructions ' * 10, history, prompt, 512),
            prompt);
        expect(history, [
          {'role': 'user', 'content': prompt}
        ]);
      }
    });

    test('context trimming keeps complete turns for strict chat templates', () {
      const prompt = 'Create hello.txt';
      final history = [
        {'role': 'user', 'content': 'old request ' * 150},
        {'role': 'assistant', 'content': 'old answer'},
        {'role': 'user', 'content': prompt},
      ];
      expect(ChatToolService.fitToContext('', history, prompt, 1024), prompt);
      expect(history, [
        {'role': 'user', 'content': prompt}
      ]);
      final imported = [
        {'role': 'assistant', 'content': 'Imported greeting'},
        {'role': 'user', 'content': prompt},
      ];
      ChatToolService.fitToContext('', imported, prompt, 1024);
      expect(imported.first['role'], 'user');
    });

    test('optional tool text shrinks while the original request and rules stay',
        () {
      const request = 'Summarize this HTML file';
      final prompt = '$request\n\n<html>Platformer Quest ${'canvas ' * 900}';
      final history = [
        {'role': 'user', 'content': prompt}
      ];
      final turn = ChatToolService.fitTurn(
        baseSystem: 'Use the file contents.',
        system: 'Use the file contents. ${'tool descriptions ' * 300}',
        prompt: prompt,
        history: history,
        contextSize: 512,
        request: request,
        needsEvidence: true,
      );
      expect(turn.system, 'Use the file contents.');
      expect(turn.prompt, startsWith('$request\n\n<html>Platformer Quest'));
      expect(turn.prompt.length, lessThan(prompt.length));
      expect(turn.history.last['content'], turn.prompt);
      expect(history.last['content'], prompt);
    });

    test(
        'rejects oversized mandatory instructions without cropping the user request',
        () {
      final prompt = 'first ${'middle ' * 500}last';
      final history = [
        {'role': 'user', 'content': prompt}
      ];
      expect(() => ChatToolService.fitToContext('', history, prompt, 1024),
          throwsStateError);
      expect(history.single['content'], prompt);
      expect(
          () => ChatToolService.fitToContext(
              'rule ' * 1000,
              [
                {'role': 'user', 'content': 'hello'}
              ],
              'hello',
              512),
          throwsStateError);
    });
  });

  group('evaluateExpression', () {
    test('handles precedence, parentheses, power and functions', () {
      expect(evaluateExpression('2+3*4'), 14);
      expect(evaluateExpression('(2+3)*4'), 20);
      expect(evaluateExpression('2^3^2'), 512);
      expect(evaluateExpression('-3+sqrt(16)'), 1);
      expect(evaluateExpression('10 % 4'), 2);
    });

    test('rejects bad input', () {
      expect(() => evaluateExpression('1/0'), throwsFormatException);
      expect(() => evaluateExpression('2+'), throwsFormatException);
      expect(() => evaluateExpression('system("ls")'), throwsFormatException);
    });
  });
}
