import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neuromesh_ai/services/agent_service.dart';
import 'package:neuromesh_ai/services/agent_tools.dart';
import 'package:neuromesh_ai/services/tool_registry.dart';
import 'package:neuromesh_ai/services/mcp_client.dart';
import 'package:neuromesh_ai/services/hive_service.dart';
import 'package:neuromesh_ai/services/user_files.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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
      expect(history, [
        {'role': 'user', 'content': prompt}
      ]);
      final imported = [
        {'role': 'assistant', 'content': 'Imported greeting'},
        {'role': 'user', 'content': prompt},
      ];
      AgentService.fitToContext('', imported, prompt, 1024);
      expect(imported.first['role'], 'user');
    });

    test('tool result envelopes and their native call survive fitting intact',
        () {
      final result = jsonEncode({
        'tool_results': [
          {
            'id': 'step_1',
            'name': 'read_file',
            'status': 'ok',
            'content': 'astronomy'
          }
        ],
        'untrusted': true
      });
      final call = {
        'role': 'assistant',
        'content':
            '<tool_call>{"name":"read_file","arguments":{"name":"a.txt"}}</tool_call>',
        '_nm_tools': 'true'
      };
      final turn = AgentService.fitTurn(
          baseSystem: 'Safety rules.',
          system: 'Safety rules.',
          prompt: result,
          history: [
            {'role': 'user', 'content': 'old ' * 500},
            call,
            {'role': 'user', 'content': result, '_nm_results': 'true'}
          ],
          contextSize: 1024,
          request: 'Read astronomy',
          continuationRequest: 'Current user request: Read astronomy');
      expect(jsonDecode(turn.prompt)['tool_results'][0]['id'], 'step_1');
      expect(turn.history[1], call);
      expect(turn.history.last['_nm_results'], 'true');
      final earlier = {
        'role': 'user',
        'content': 'Earlier verified output: astronomy.txt'
      };
      final ample = AgentService.fitTurn(
          baseSystem: 'Safety rules.',
          system: 'Safety rules.',
          prompt: result,
          history: [
            earlier,
            call,
            {'role': 'user', 'content': result, '_nm_results': 'true'}
          ],
          contextSize: 4096,
          request: 'Read astronomy');
      expect(ample.history.first, earlier);

      expect(
          () => AgentService.fitTurn(
              baseSystem: 'Safety rules.',
              system: 'Safety rules.',
              prompt: result,
              history: [
                call,
                {'role': 'user', 'content': result, '_nm_results': 'true'}
              ],
              contextSize: 64,
              request: 'Read astronomy'),
          throwsStateError);
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

  test('tool availability is independent of request keywords', () {
    Get.put(HiveService());
    addTearDown(Get.reset);
    final agent = AgentService();
    for (final text in [
      'Hi',
      'What is gravity?',
      'Paint a galaxy',
      'Save a file'
    ]) {
      expect(agent.wantsTools(text), isTrue);
    }
    agent.mode.value = AgentChatMode.off;
    expect(agent.wantsTools('Search the internet'), isFalse);
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
      generate: (_, history, ___) async => history.length <= 1
          ? '<tool_call>{"name":"text_to_speech","arguments":{"text":"hello Carlos","name":"speech.wav"}}</tool_call>'
          : 'Audio is ready: [Audio](nmfile:speech.wav)',
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

  test('a compact model prompt lets the agent discover and then use a tool',
      () async {
    Get.put(HiveService());
    addTearDown(Get.reset);
    final agent = AgentService();
    final toolPrompt = agent.toolPrompt(
        request: 'Could you narrate this?', contextSize: 1024, maxTokens: 120);
    expect(toolPrompt, contains('search_tools'));
    expect(agent.wantsTools('Could you narrate this?'), isTrue);
    expect(agent.wantsTools('Explain why the sky is blue'), isTrue);

    var generation = 0;
    final result = await agent.runToolLoop(
      prompt: 'Calculate the sum',
      history: const [],
      confirm: (_, __, ___) async => false,
      onVisible: (_) {},
      onStatus: (_) {},
      cancelled: () => false,
      generate: (prompt, _, __) async {
        generation++;
        switch (generation) {
          case 1:
            return '<tool_call>{"name":"search_tools","arguments":{"query":"calculate a sum"}}</tool_call>';
          case 2:
            expect(prompt, contains('calculator:'));
            expect(prompt, contains('tool_results'));
            return '<tool_call>{"name":"calculator","arguments":{"expression":"2+3"}}</tool_call>';
          default:
            expect(prompt, contains('5'));
            return 'The sum is 5.';
        }
      },
    );
    expect(result.answer, 'The sum is 5.');
    expect(result.trace, hasLength(2));
  });

  test('tool search finds TTS and hides blocked and unavailable tools',
      () async {
    Get.put(HiveService());
    addTearDown(Get.reset);
    final agent = AgentService();
    Future<String> search(String text) => agent.executeTool(
        ParsedToolCall('search_tools', {'query': text}, ''),
        (_, __, ___) async => false);
    expect(await search('TTS'), isNot(contains('text_to_speech:')));
    expect(await search('STT'), isNot(contains('transcribe_audio:')));
    expect(
        await search('delete_user_file'), isNot(contains('delete_user_file:')));
    agent.policy[AgentService.keyOf('built-in', 'text_to_speech')] = 'block';
    expect(await search('TTS'), isNot(contains('text_to_speech:')));
  });

  test('shared folder changes require approval and stay on the selected tree',
      () async {
    final dir = await Directory.systemTemp.createTemp('shared_folder');
    Hive.init(dir.path);
    addTearDown(() async {
      Get.reset();
      await Hive.close();
      await dir.delete(recursive: true);
    });
    Get.put(await HiveService().init());
    final files = Get.put(UserFilesService());
    const folder = GrantedFolder('content://docs/tree/shared', 'Shared');
    files.folders.add(folder);
    const channel = MethodChannel('com.neuromesh.ai/device');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final requested = <Map>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'mutateSharedFile');
      final args = call.arguments as Map;
      requested.add(args);
      return args['name'] ?? args['path'];
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
    });

    final agent = AgentService();
    Future<String> use(String action,
            {bool allow = true, String folder = 'Shared'}) =>
        agent.executeTool(
          ParsedToolCall(
              action,
              {
                'folder': folder,
                'path': 'drafts/report.txt',
                if (action == 'rename_user_file') 'name': 'final.txt',
                if (action == 'append_user_file') 'content': 'new paragraph',
              },
              ''),
          (_, __, ___) async => allow,
        );
    expect(await use('delete_user_file', allow: false), contains('denied'));
    expect(await use('delete_user_file', folder: 'Something else'),
        contains('exact name'));
    expect(requested, isEmpty);
    expect(await use('append_user_file'), startsWith('Appended'));
    expect(await use('rename_user_file'),
        'Renamed drafts/report.txt to final.txt.');
    expect(await use('delete_user_file'), 'Deleted drafts/report.txt.');
    expect(await use('create_user_folder'), startsWith('Created folder'));
    expect(requested.map((args) => args['action']),
        ['append', 'rename', 'delete', 'mkdir']);
    expect(requested.map((args) => args['uri']).toSet(), {folder.uri});
  });

  test('repeated context searches finish with one synthesis pass', () async {
    Get.put(HiveService());
    addTearDown(Get.reset);
    final agent = AgentService();
    agent.addTool(AgentTool('search_context', 'Search context', '{}',
        (_) async => 'No matching excerpt.'));
    var generations = 0;
    final result = await agent.runToolLoop(
      prompt: 'Write a short answer',
      history: const [],
      confirm: (_, __, ___) async => true,
      cancelled: () => false,
      onVisible: (_) {},
      onStatus: (_) {},
      generate: (prompt, history, _) async {
        generations++;
        if (prompt == AgentService.finalAnswerPrompt) {
          return 'I could not find the requested information.';
        }
        return '<tool_call>{"name":"search_context","arguments":{"query":"topic"}}</tool_call>';
      },
    );
    expect(generations, 2);
    expect(result.trace, hasLength(1));
    expect(result.answer, contains('repeated tool call'));
    expect(result.hitLimit, isTrue);
  });

  test('structured adapter rejects malformed calls and ignores prose JSON', () {
    expect(decodeModelCalls('Example: {"name":"write_file","arguments":{}}'),
        isEmpty);
    expect(
        decodeModelCalls('```json\n{"name":"write_file","arguments":{}}\n```'),
        isEmpty);
    expect(() => decodeModelCalls('<tool_call>{"name":"x"}</tool_call>'),
        throwsFormatException);
    expect(() => decodeModelCalls('<tool_call>{"name":"x","arguments":{}}'),
        throwsFormatException);
    expect(
        decodeModelCalls(
                '<think>reasoning</think><tool_call>{"name":"calculator","arguments":{"expression":"2+2"}}</tool_call>')
            .single
            .name,
        'calculator');
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
  Future<String> executeTool(ParsedToolCall call, ToolConfirm confirm,
      {bool userRequestedOnlineImage = false}) async {
    this.call = call;
    return 'Saved speech.wav. Show it with [📎 speech.wav](nmfile:speech.wav).';
  }
}
