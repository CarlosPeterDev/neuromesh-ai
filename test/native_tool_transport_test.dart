import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neuromesh_ai/core/constants.dart';
import 'package:neuromesh_ai/services/agent_service.dart';
import 'package:neuromesh_ai/services/cloud_service.dart';
import 'package:neuromesh_ai/services/hive_service.dart';
import 'package:neuromesh_ai/services/tool_registry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'native provider round trip preserves schemas, call IDs and tool result roles (mock HTTP)',
      () async {
    final dir = await Directory.systemTemp.createTemp('native-tools-');
    Hive.init(dir.path);
    final hive = Get.put(await HiveService().init());
    addTearDown(() async {
      Get.reset();
      await Hive.close();
      await dir.delete(recursive: true);
    });
    await hive.setSetting(AppConstants.keyCloudProvider, 'openai');
    await hive.setSetting(AppConstants.keyOpenaiKey, 'test-only-key');
    var requests = 0;
    final cloud = CloudService(
        agentClientFactory: () => MockClient((req) async {
              final body = jsonDecode(req.body) as Map;
              expect(body['tools'], isNotEmpty);
              expect(body['tool_choice'], 'auto');
              expect(req.headers['authorization'], 'Bearer test-only-key');
              requests++;
              if (requests == 1) {
                expect((body['messages'] as List).last['content'],
                    'Calculate 12*13');
                return http.Response(
                    jsonEncode({
                      'choices': [
                        {
                          'message': {
                            'content': null,
                            'tool_calls': [
                              {
                                'id': 'provider-id',
                                'type': 'function',
                                'function': {
                                  'name': 'calculator',
                                  'arguments': '{"expression":"12*13"}'
                                }
                              }
                            ]
                          }
                        }
                      ]
                    }),
                    200);
              }
              final messages = body['messages'] as List;
              final assistant =
                  messages.firstWhere((m) => m['tool_calls'] != null);
              final result = messages.firstWhere((m) => m['role'] == 'tool');
              expect(result['tool_call_id'], assistant['tool_calls'][0]['id']);
              expect(jsonDecode(result['content'])['content'], '156');
              expect(jsonDecode(result['content'])['status'], 'ok');
              return http.Response(
                  jsonEncode({
                    'choices': [
                      {
                        'message': {'content': '156'}
                      }
                    ]
                  }),
                  200);
            }));
    final agent = AgentService();
    final result = await agent.runToolLoop(
        prompt: 'Calculate 12*13',
        history: [],
        confirm: (_, __, ___) async => true,
        onVisible: (_) {},
        onStatus: (_) {},
        cancelled: () => false,
        generate: (_, history, onToken) => cloud.sendAgentMessage(
            messages: history,
            tools: agent.registry.schemas,
            onToken: onToken));
    expect(result.answer, '156');
    expect(result.trace, hasLength(1));
    expect(requests, 2);
  });
  for (final provider in ['google', 'anthropic']) {
    test(
        '$provider native schemas, result roles and opaque signatures round trip (mock HTTP)',
        () async {
      final dir = await Directory.systemTemp.createTemp('native-$provider-');
      Hive.init(dir.path);
      final hive = Get.put(await HiveService().init());
      addTearDown(() async {
        Get.reset();
        await Hive.close();
        await dir.delete(recursive: true);
      });
      await hive.setSetting(AppConstants.keyCloudProvider, provider);
      await hive.setSetting(
          provider == 'google'
              ? AppConstants.keyGoogleKey
              : AppConstants.keyAnthropicKey,
          'test-only');
      var requests = 0;
      final cloud = CloudService(
          agentClientFactory: () => MockClient((request) async {
                requests++;
                final body = jsonDecode(request.body);
                if (provider == 'google') {
                  expect(
                      body['tools'][0]['functionDeclarations'][0]
                          ['parametersJsonSchema']['type'],
                      'object');
                  expect(request.headers['x-goog-api-key'], 'test-only');
                  if (requests == 1)
                    return http.Response(
                        jsonEncode({
                          'candidates': [
                            {
                              'content': {
                                'parts': [
                                  {
                                    'functionCall': {
                                      'name': 'calculator',
                                      'args': {'expression': '12*13'}
                                    },
                                    'thoughtSignature': 'opaque-signature'
                                  }
                                ]
                              }
                            }
                          ]
                        }),
                        200);
                  final contents = body['contents'] as List;
                  final model =
                      contents.firstWhere((m) => m['role'] == 'model');
                  expect(model['parts'][0]['thoughtSignature'],
                      'opaque-signature');
                  expect(contents.last['parts'][0]['functionResponse']['name'],
                      'calculator');
                  expect(
                      contents.last['parts'][0]['functionResponse']['response']
                          ['content'],
                      '156');
                  return http.Response(
                      jsonEncode({
                        'candidates': [
                          {
                            'content': {
                              'parts': [
                                {'text': '156'}
                              ]
                            }
                          }
                        ]
                      }),
                      200);
                }
                expect(body['tools'][0]['input_schema']['type'], 'object');
                expect(request.headers['x-api-key'], 'test-only');
                if (requests == 1)
                  return http.Response(
                      jsonEncode({
                        'content': [
                          {
                            'type': 'tool_use',
                            'id': 'toolu_test',
                            'name': 'calculator',
                            'input': {'expression': '12*13'}
                          }
                        ]
                      }),
                      200);
                final result = (body['messages'] as List).last['content'][0];
                expect(result['type'], 'tool_result');
                expect(result['tool_use_id'], 'toolu_test');
                expect(jsonDecode(result['content'])['content'], '156');
                return http.Response(
                    jsonEncode({
                      'content': [
                        {'type': 'text', 'text': '156'}
                      ]
                    }),
                    200);
              }));
      final agent = AgentService();
      final result = await agent.runToolLoop(
          prompt: 'Calculate 12*13',
          history: [],
          confirm: (_, __, ___) async => true,
          onVisible: (_) {},
          onStatus: (_) {},
          cancelled: () => false,
          generate: (_, history, onToken) => cloud.sendAgentMessage(
              messages: history,
              tools: agent.registry.schemas,
              onToken: onToken));
      expect(result.answer, '156');
      expect(requests, 2);
    });
  }
  test(
      'native provider text quoting tool syntax is never a function-call event',
      () async {
    final dir = await Directory.systemTemp.createTemp('native-text-');
    Hive.init(dir.path);
    final hive = Get.put(await HiveService().init());
    addTearDown(() async {
      Get.reset();
      await Hive.close();
      await dir.delete(recursive: true);
    });
    await hive.setSetting(AppConstants.keyCloudProvider, 'openai');
    await hive.setSetting(AppConstants.keyOpenaiKey, 'test-only');
    var actions = 0;
    final agent = AgentService();
    agent.addTool(AgentTool('probe', 'Probe', '{}', (_) {
      actions++;
      return 'ok';
    }));
    final quoted = encodeModelCalls([const ModelToolCall('probe', {})]);
    final cloud = CloudService(
        agentClientFactory: () => MockClient((_) async => http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': quoted}
                }
              ]
            }),
            200)));
    final result = await agent.runToolLoop(
        prompt: 'Show a protocol example',
        history: [],
        confirm: (_, __, ___) async => true,
        onVisible: (_) {},
        onStatus: (_) {},
        cancelled: () => false,
        generate: (_, history, onToken) => cloud.sendAgentMessage(
            messages: history,
            tools: agent.registry.schemas,
            onToken: onToken));
    expect(result.answer, quoted);
    expect(result.trace, isEmpty);
    expect(actions, 0);
  });
}
