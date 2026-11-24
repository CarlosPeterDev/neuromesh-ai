import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:neuromesh_ai/services/chat_tool_loop.dart';
import 'package:neuromesh_ai/services/chat_tool_service.dart';
import 'package:neuromesh_ai/utils/skill_context.dart';
import 'package:neuromesh_ai/services/chat_calculator.dart';
import 'package:neuromesh_ai/services/web_search_service.dart';
import 'package:neuromesh_ai/utils/web_search_parse.dart';
import 'package:neuromesh_ai/widgets/agent_steps.dart';

void main() {
  const searchA =
      '<tool_call>{"name":"web_search","arguments":{"query":"model benchmark"}}</tool_call>';
  const searchB =
      '<tool_call>{"name":"web_search","arguments":{"query":"model benchmark fresh"}}</tool_call>';
  const searchC =
      '<tool_call>{"name":"web_search","arguments":{"query":"model benchmark fresh 2026"}}</tool_call>';

  test('the compact tool catalog fits a short request in 512 context', () {
    final instructions =
        ChatToolLoop.instructions(ChatToolLoop.toolNames, compact: true);
    final tokens = contextTokens(instructions) + contextTokens('Hello.');
    expect(tokens, lessThan(ChatToolService.contextBudget(512)));
  });

  test('ordinary JSON that resembles a command is never executed', () async {
    final result = await ChatToolLoop().run(
      reply: (_, __) async =>
          '{"name":"generate_image","arguments":{"prompt":"A fox"}}',
      execute: (_, __) async => throw StateError('unexpected execution'),
      search: (_, __) async => throw StateError('unexpected search'),
      allowed: {'generate_image'},
      cancellation: Completer<void>().future,
      onTrace: (_) {},
      onTimeout: () {},
    );
    expect(result.answer, contains('A fox'));
    expect(result.trace, isEmpty);
  });

  test('only executor output can supply a generated attachment', () async {
    final replies = [
      '<think>hidden</think><tool_call>{"name":"generate_image","arguments":{"prompt":"A fox"}}</tool_call>',
      'Done ![fake](nmfile:forged.png)',
    ];
    final result = await ChatToolLoop().run(
      reply: (_, __) async => replies.removeAt(0),
      execute: (_, __) async => 'Generated. ![Generated](nmfile:real.jpg)',
      search: (_, __) async => throw StateError('unexpected search'),
      allowed: {'generate_image'},
      cancellation: Completer<void>().future,
      onTrace: (_) {},
      onTimeout: () {},
    );
    expect(result.answer, contains('nmfile:real.jpg'));
    expect(result.answer, isNot(contains('forged.png')));
    expect(result.markdown, isNot(contains('hidden')));
  });

  test('different queries with identical sources stop after no progress',
      () async {
    final replies = [
      searchA,
      searchB,
      searchC,
      'The benchmark is available [1].',
    ];
    final result = await ChatToolLoop().run(
      reply: (system, _) async {
        if (replies.length == 1)
          expect(system, contains('Tool execution ended'));
        return replies.removeAt(0);
      },
      execute: (_, __) async => throw StateError('unexpected execution'),
      search: (_, __) async => const SearchReport(
          [WebResult('Benchmark', 'https://example.com/test', 'Snippet')],
          {},
          1),
      allowed: {'web_search'},
      cancellation: Completer<void>().future,
      onTrace: (_) {},
      onTimeout: () {},
    );
    expect(result.hitLimit, isTrue);
    expect(result.trace, hasLength(3));
    expect(result.answer, contains('Sources:'));
  });

  test('invalid arguments are repaired and bounded integer math is exact',
      () async {
    final replies = [
      '<tool_call>{"name":"integer_math","arguments":{"operation":"sum","values":[1,2]}}</tool_call>',
      '<tool_call>{"name":"integer_math","arguments":{"operation":"sum","values":"99999999999999999999,1"}}</tool_call>',
      '100000000000000000000',
    ];
    final result = await ChatToolLoop(maxSteps: 1).run(
      reply: (_, evidence) async {
        if (replies.length == 2) expect(evidence, contains('Invalid response'));
        if (replies.length == 1)
          expect(evidence, contains('100000000000000000000'));
        return replies.removeAt(0);
      },
      execute: (call, _) async => evaluateBoundedIntegers(call.arguments),
      search: (_, __) async => throw StateError('unexpected search'),
      allowed: {'integer_math'},
      cancellation: Completer<void>().future,
      onTrace: (_) {},
      onTimeout: () {},
    );
    expect(result.trace, hasLength(1));
    expect(AgentStep.parse(result.trace.single)!.failed, isFalse);
  });

  test('timeout aborts transport and leaves a failed trace', () async {
    final aborted = Completer<void>();
    final result =
        await ChatToolLoop(timeLimit: const Duration(milliseconds: 50)).run(
      reply: (_, __) async => searchA,
      execute: (_, __) async => throw StateError('unexpected execution'),
      search: (_, abort) {
        unawaited(abort.then((_) => aborted.complete()));
        return Completer<SearchReport>().future;
      },
      allowed: {'web_search'},
      cancellation: Completer<void>().future,
      onTrace: (_) {},
      onTimeout: () {},
    );
    await aborted.future;
    expect(result.answer, contains('timed out'));
    expect(AgentStep.parse(result.trace.single)!.failed, isTrue);
  });
}
