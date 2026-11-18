import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neuromesh_ai/services/agent_service.dart';
import 'package:neuromesh_ai/services/agent_tools.dart';
import 'package:neuromesh_ai/services/mcp_client.dart';

void main() {
  group('local chat context fitting', () {
    test('preserves short voice and ordinary requests under context pressure', () {
      for (final prompt in [
        'Create audio file that says hello Carlos using tts tool',
        'Can you explain it?',
        '',
      ]) {
        final history = [
          {'role': 'assistant', 'content': 'old answer ' * 200},
          {'role': 'user', 'content': prompt},
        ];
        expect(AgentService.fitToContext('instructions ' * 100, history, prompt, 512),
            prompt);
        expect(history, [{'role': 'user', 'content': prompt}]);
      }
    });

    test('shortens a long request and keeps the prompt and history in sync', () {
      final prompt = 'first ${'middle ' * 500}last';
      final history = [{'role': 'user', 'content': prompt}];
      final fitted = AgentService.fitToContext('', history, prompt, 1024);

      expect(fitted, startsWith('first '));
      expect(fitted, endsWith('last'));
      expect(fitted.length, lessThan(prompt.length));
      expect(history.single['content'], fitted);
    });
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
      final c = parseToolCall('<tool_call>{"name":"x","arguments":{"q":"a } b"}}');
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
    const cfg = McpServerConfig(id: '1', name: 'Demo Server', url: 'https://x.test/mcp', token: 'tok');

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
          if (method == 'notifications/initialized') return http.Response('', 202);
          Map<String, dynamic> result;
          if (method == 'initialize') {
            result = {'protocolVersion': '2025-03-26'};
          } else if (method == 'tools/list') {
            result = {
              'tools': [
                {'name': 'echo', 'description': 'Echo', 'inputSchema': {'type': 'object'}}
              ]
            };
          } else {
            result = {
              'content': [
                {'type': 'text', 'text': 'hi ${(body['params'] as Map)['arguments']['msg']}'}
              ]
            };
          }
          final json = jsonEncode({'jsonrpc': '2.0', 'id': body['id'], 'result': result});
          // Answer tools/call as an SSE stream to cover both transports.
          if (method == 'tools/call') {
            return http.Response('event: message\ndata: $json\n\n', 200,
                headers: {'content-type': 'text/event-stream'});
          }
          return http.Response(json, 200, headers: {'content-type': 'application/json'});
        }),
      );
      final tools = await client.listTools();
      expect(tools.single.name, 'echo');
      expect(tools.single.qualifiedName, 'demo_server__echo');
      final out = await client.callTool('echo', {'msg': 'there'});
      expect(out, 'hi there');
      expect(auth, 'Bearer tok');
      expect(methods, ['initialize', 'notifications/initialized', 'tools/list', 'tools/call']);
    });

    test('reports auth and server errors readably', () async {
      final client = McpClient(cfg, client: MockClient((_) async => http.Response('no', 401)));
      expect(client.listTools(), throwsA(isA<McpException>()));
    });
  });
}
