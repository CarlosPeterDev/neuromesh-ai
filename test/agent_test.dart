import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neuromesh_ai/services/agent_service.dart';
import 'package:neuromesh_ai/services/agent_tools.dart';
import 'package:neuromesh_ai/services/mcp_client.dart';
import 'package:neuromesh_ai/services/hive_service.dart';

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
            AgentService.fitToContext(
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
      expect(AgentService.fitToContext('', history, prompt, 1024), prompt);
      expect(history, [{'role': 'user', 'content': prompt}]);
      final imported = [
        {'role': 'assistant', 'content': 'Imported greeting'},
        {'role': 'user', 'content': prompt},
      ];
      AgentService.fitToContext('', imported, prompt, 1024);
      expect(imported.first['role'], 'user');
    });

    test('optional tool text shrinks while the original request and rules stay',
        () {
      const request = 'Summarize this HTML file';
      final prompt = '$request\n\n<html>Platformer Quest ${'canvas ' * 900}';
      final history = [
        {'role': 'user', 'content': prompt}
      ];
      final turn = AgentService.fitTurn(
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
      expect(() => AgentService.fitToContext('', history, prompt, 1024),
          throwsStateError);
      expect(history.single['content'], prompt);
      expect(
          () => AgentService.fitToContext(
              'rule ' * 1000,
              [
                {'role': 'user', 'content': 'hello'}
              ],
              'hello',
              512),
          throwsStateError);
    });
  });

  test('greetings bypass tools even in Always mode, while tasks keep them', () {
    Get.put(HiveService());
    addTearDown(Get.reset);
    final agent = AgentService()..mode.value = AgentChatMode.always;
    expect(agent.wantsTools('Hi'), isFalse);
    expect(agent.wantsTools('Helli!'), isFalse);
    expect(agent.wantsTools('السلام عليكم'), isFalse);
    expect(agent.wantsTools('Hi', hasFile: true), isTrue);
    expect(agent.wantsTools('Create a file in the workspace named hello.txt'),
        isTrue);
  });

  test('routes literal speech and leaves voice overrides to the model', () {
    expect(
      literalSpeechText(
          'Create audio file that says hello Carlos using tts tool'),
      'hello Carlos',
    );
    expect(
        literalSpeechText('Make a WAV file saying "Hello!" using the TTS tool'),
        'Hello!');
    expect(
        literalSpeechText(
            'Create audio file that says hello Carlos using tts tool with voice af_heart'),
        isNull);
    expect(literalSpeechText('Can you create a file'), isNull);
    expect(literalSpeechText('Create a file audio says hello Carlos'),
        'hello Carlos');
    expect(
        literalSpeechText(
            'Use the tts tool and create audio file says hello carlos'),
        'hello carlos');
    expect(
        literalSpeechText(
            'Use the TTS tool to create a file says hello Carlos'),
        'hello Carlos');
  });

  test('recognizes an explicitly named empty workspace file', () {
    expect(namedWorkspaceFile('Create a file in the workspace named hello.txt'),
        'hello.txt');
    expect(
        namedWorkspaceFile(
            'Create a file in the workspace named hello.txt with my notes'),
        isNull);
    expect(namedWorkspaceFile('Can you create a file'), isNull);
  });

  test(
      'explicit TTS runs the tool, exposes progress and returns the audio link',
      () async {
    Get.put(HiveService());
    addTearDown(Get.reset);
    final agent = _SpeechTestAgent();
    final traceUpdates = <List<String>>[];
    const prompt = 'Create audio file that says hello Carlos using tts tool';
    final result = await agent.runToolLoop(
      generate: (_, __, ___) async =>
          throw StateError('LLM should not be called'),
      prompt: prompt,
      history: [
        {'role': 'user', 'content': prompt}
      ],
      confirm: (_, __, ___) async => true,
      onVisible: (_) {},
      onStatus: (_) {},
      onTrace: traceUpdates.add,
      cancelled: () => false,
    );

    expect(agent.call?.name, 'text_to_speech');
    expect(agent.call?.arguments['text'], 'hello Carlos');
    expect(agent.call?.arguments['name'], endsWith('.wav'));
    expect(result.answer, contains('(nmfile:speech.wav)'));
    expect(traceUpdates.first.single, contains('"run":true'));
    expect(traceUpdates.last.single, contains('"run":false'));
  });

  group('parseToolCall', () {
    test('reads a normal call', () {
      final c = parseToolCall(
          'Let me check.\n<tool_call>{"name":"calculator","arguments":{"expression":"2+2"}}</tool_call>');
      expect(c, isNotNull);
      expect(c!.name, 'calculator');
      expect(c.arguments['expression'], '2+2');
      expect(c.textBefore, 'Let me check.');
    });

    test('tolerates a missing closing tag and braces inside strings', () {
      final c =
          parseToolCall('<tool_call>{"name":"x","arguments":{"q":"a } b"}}');
      expect(c?.arguments['q'], 'a } b');
    });

    test('returns null for plain answers and broken json', () {
      expect(parseToolCall('The answer is 4.'), isNull);
      expect(parseToolCall('<tool_call>{"name": </tool_call>'), isNull);
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

  group('McpClient', () {
    const cfg = McpServerConfig(
        id: '1', name: 'Demo Server', url: 'https://x.test/mcp', token: 'tok');

    test('initializes, lists tools and calls a tool', () async {
      final methods = <String>[];
      String? auth;
      final client = McpClient(
        cfg,
        client: MockClient((req) async {
          auth = req.headers['Authorization'];
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          final method = body['method'] as String;
          methods.add(method);
          if (method == 'notifications/initialized')
            return http.Response('', 202);
          Map<String, dynamic> result;
          if (method == 'initialize') {
            result = {'protocolVersion': '2025-03-26'};
          } else if (method == 'tools/list') {
            result = {
              'tools': [
                {
                  'name': 'echo',
                  'description': 'Echo',
                  'inputSchema': {'type': 'object'}
                }
              ]
            };
          } else {
            result = {
              'content': [
                {
                  'type': 'text',
                  'text': 'hi ${(body['params'] as Map)['arguments']['msg']}'
                }
              ]
            };
          }
          final json = jsonEncode(
              {'jsonrpc': '2.0', 'id': body['id'], 'result': result});
          // Answer tools/call as an SSE stream to cover both transports.
          if (method == 'tools/call') {
            return http.Response('event: message\ndata: $json\n\n', 200,
                headers: {'content-type': 'text/event-stream'});
          }
          return http.Response(json, 200,
              headers: {'content-type': 'application/json'});
        }),
      );
      final tools = await client.listTools();
      expect(tools.single.name, 'echo');
      expect(tools.single.qualifiedName, 'demo_server__echo');
      final out = await client.callTool('echo', {'msg': 'there'});
      expect(out, 'hi there');
      expect(auth, 'Bearer tok');
      expect(methods, [
        'initialize',
        'notifications/initialized',
        'tools/list',
        'tools/call'
      ]);
    });

    test('reports auth and server errors readably', () async {
      final client = McpClient(cfg,
          client: MockClient((_) async => http.Response('no', 401)));
      expect(client.listTools(), throwsA(isA<McpException>()));
    });
  });
}

class _SpeechTestAgent extends AgentService {
  ParsedToolCall? call;

  @override
  Future<String> executeTool(ParsedToolCall call, ToolConfirm confirm) async {
    this.call = call;
    return 'Saved speech.wav. Show it with [📎 speech.wav](nmfile:speech.wav).';
  }
}
