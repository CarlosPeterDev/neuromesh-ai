// Deterministic orchestration integration tests: scripted model/provider and
// Android method channels, real workspace files and real WAV/PNG encoding.
// These are not live model, Pollinations, Android SAF, or Android TTS tests.
import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:image/image.dart' as img;
import 'package:hive/hive.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:neuromesh_ai/services/agent_service.dart';
import 'package:neuromesh_ai/services/agent_tools.dart';
import 'package:neuromesh_ai/services/hive_service.dart';
import 'package:neuromesh_ai/services/pollinations_image_service.dart';
import 'package:neuromesh_ai/services/tool_registry.dart';
import 'package:neuromesh_ai/services/user_files.dart';
import 'package:neuromesh_ai/services/voice_service.dart';
import 'package:neuromesh_ai/services/web_search_service.dart';
import 'package:neuromesh_ai/utils/web_search_parse.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late _DiskAgent agent;
  late _Images images;
  late _Web web;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('agent-integration-');
    Hive.init('${dir.path}/db');
    final workspace = await Directory('${dir.path}/outputs').create();
    Get.put(await HiveService().init());
    Get.put<VoiceService>(_Voice());
    web = _Web();
    Get.put<WebSearchService>(web);
    images = _Images();
    agent = _DiskAgent(workspace)..imageProvider = images;
  });
  tearDown(() async {
    Get.reset();
    await Hive.close();
    await dir.delete(recursive: true);
  });

  Future<ToolLoopResult> run(List<String> responses,
      {bool allow = true,
      String request = 'Do the task',
      bool Function()? cancelled}) {
    var turns = 0;
    return agent.runToolLoop(
        prompt: request,
        history: [],
        confirm: (_, __, ___) async => allow,
        onVisible: (_) {},
        onStatus: (_) {},
        cancelled: cancelled ?? () => false,
        generate: (_, history, __) async {
          if (turns == 0) {
            expect(await agent.dir.list().length, 0);
            expect(images.prompts, isEmpty);
            expect(web.queries, isEmpty);
          }
          expect(turns, lessThan(responses.length));
          return responses[turns++];
        });
  }

  String call(String name, Map<String, dynamic> args) =>
      encodeModelCalls([ModelToolCall(name, args)]);

  test('a later inference failure preserves verified output links', () async {
    var turns = 0;
    final result = await agent.runToolLoop(
        prompt: 'Save astronomy',
        history: [],
        confirm: (_, __, ___) async => true,
        onVisible: (_) {},
        onStatus: (_) {},
        cancelled: () => false,
        generate: (_, __, ___) async {
          if (turns++ == 0)
            return call('write_file',
                {'name': 'astronomy.txt', 'content': 'Stars form in nebulae.'});
          throw StateError('context exhausted');
        });
    expect(await File('${agent.dir.path}/astronomy.txt').readAsString(),
        'Stars form in nebulae.');
    expect(result.answer, contains('context exhausted'));
    expect(result.answer, contains('nmfile:astronomy.txt'));
  });

  test('direct questions and image/audio/file keywords execute no tools',
      () async {
    final result = await run(['The sky scatters blue light.'],
        request:
            'What is the sky? Explain how to create image and audio files.');
    expect(result.trace, isEmpty);
    expect(web.queries, isEmpty);
    expect(images.prompts, isEmpty);
  });

  test(
      'compound plan carries text to WAV, generates distinct images and searches',
      () async {
    const paragraph = 'Astronomy studies stars and galaxies.';
    final result = await run([
      call('write_file', {'name': 'astronomy.txt', 'content': paragraph}),
      call('text_to_speech',
          {'source': 'astronomy.txt', 'name': 'astronomy.wav'}),
      encodeModelCalls([
        for (final subject in ['Moon', 'Saturn', 'Orion'])
          ModelToolCall(
              'generate_image', {'prompt': subject, 'name': '$subject.png'})
      ]),
      call('web_search', {'query': 'recent astronomy discoveries'}),
      'The paragraph, narration, and three images were saved. The mocked discovery is described in the results.',
    ]);
    expect(result.hitLimit, isFalse);
    expect(result.trace, hasLength(6));
    expect(await File('${agent.dir.path}/astronomy.txt').readAsString(),
        paragraph);
    final audio = await File('${agent.dir.path}/astronomy.wav').readAsBytes();
    expect(decodeWav(audio)?.samples, isNotEmpty);
    expect(images.prompts, ['Moon', 'Saturn', 'Orion']);
    for (final name in images.prompts) {
      expect(
          img.decodeImage(
              await File('${agent.dir.path}/$name.png').readAsBytes()),
          isNotNull);
      expect(result.answer, contains('nmfile:$name.png'));
    }
    expect(web.queries, ['recent astronomy discoveries']);
    expect(result.answer, contains('nmfile:astronomy.wav'));
  });

  test('model selected web only; denial prevents all provider calls', () async {
    final denied = await run([
      call('web_search', {'query': 'news'}),
      'Search was denied.'
    ], allow: false);
    expect(denied.trace.single, contains('denied'));
    expect(web.queries, isEmpty);
  });

  test('invalid, unavailable, and removed tools cannot execute', () async {
    final result = await run([
      call('write_file', {'name': 'bad.txt', 'content': 42}),
      call('opencode', {}),
      call('write_file', {'name': '../outside.txt', 'content': 'no'}),
      'The requested actions failed.',
    ]);
    expect(result.trace, hasLength(3));
    expect(await agent.dir.list().length, 0);
    expect(result.trace.join(), contains('must be string'));
    expect(agent.registry.schemas.toString(), isNot(contains('opencode')));
  });

  test('repeated calls stop; configured step and model timeouts are bounded',
      () async {
    var n = 0;
    agent.addTool(AgentTool('probe', 'read-only probe', '{}', (_) {
      n++;
      return 'ok';
    }));
    final repeated = await run([call('probe', {}), call('probe', {})]);
    expect(repeated.hitLimit, isTrue);
    expect(n, 1);
    agent.executionLimits = const AgentLimits(maxSteps: 1);
    final limited = await run([call('probe', {})]);
    expect(limited.hitLimit, isTrue);
    agent.executionLimits =
        const AgentLimits(modelTimeout: Duration(milliseconds: 5));
    final timed = await agent.runToolLoop(
        prompt: 'test',
        history: [],
        confirm: (_, __, ___) async => true,
        onVisible: (_) {},
        onStatus: (_) {},
        cancelled: () => false,
        generate: (_, __, ___) async {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          return 'late';
        });
    expect(timed.hitLimit, isTrue);
    expect(timed.answer, contains('timed out'));
  });

  test('cancellation before a batch member prevents later actions', () async {
    var stopped = false;
    agent.addTool(AgentTool('cancel_probe', 'Cancel', '{}', (_) {
      stopped = true;
      return 'complete';
    }));
    final result = await run([
      encodeModelCalls([
        const ModelToolCall('cancel_probe', {}),
        const ModelToolCall(
            'write_file', {'name': 'never.txt', 'content': 'no'})
      ])
    ], cancelled: () => stopped);
    expect(result.answer, contains('Cancelled'));
    expect(await agent.dir.list().length, 0);
  });

  test(
      'shared export sends actual bytes and exposes provider document URI (mock SAF)',
      () async {
    final files = Get.put(UserFilesService());
    const folder = GrantedFolder('content://provider/tree/shared', 'Shared');
    files.folders.add(folder);
    final written = <String, Uint8List>{};
    const channel = MethodChannel('com.neuromesh.ai/device');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (c) async {
      final a = c.arguments as Map;
      expect(a['uri'], folder.uri);
      if (c.method == 'writeFile') {
        written[a['path']] = a['bytes'];
        return true;
      }
      if (c.method == 'sharedFileUri')
        return 'content://provider/document/shared%2F${a['path']}';
      throw StateError('Unexpected channel method');
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final result = await run([
      call('write_file', {'name': 'paragraph.txt', 'content': 'Astronomy'}),
      call('export_file', {
        'name': 'paragraph.txt',
        'folder': 'Shared',
        'path': 'reports/paragraph.txt'
      }),
      'Export finished.',
    ]);
    expect(utf8.decode(written['reports/paragraph.txt']!), 'Astronomy');
    expect(result.trace.last, contains('content://provider/document/'));
  });

  test('model-authored plan blocks dependent work after failure', () async {
    for (final failure in [
      'Error: provider unavailable',
      'Tool error: rejected',
      'HTTP 500 failure'
    ]) {
      var dependentCalls = 0;
      agent.addTool(AgentTool('fail_step', 'Fails', '{}', (_) => failure));
      agent.addTool(
          AgentTool('dependent_step', 'Must wait for success', '{}', (_) {
        dependentCalls++;
        return 'ok';
      }));
      final result = await run([
        encodeModelCalls([
          const ModelToolCall('fail_step', {}, id: 'draft'),
          const ModelToolCall('dependent_step', {},
              id: 'audio', dependsOn: ['draft']),
        ], plan: [
          'Create the draft',
          'Narrate the completed draft'
        ]),
        'Both steps are incomplete.',
      ]);
      expect(result.plan, hasLength(2));
      expect(result.markdown, contains('Plan:'));
      expect(result.trace.last, contains('dependencies are incomplete'));
      expect(dependentCalls, 0);
    }
  });

  test(
      'revoked and read-only SAF grants change registry availability (mock Android)',
      () async {
    final files = Get.put(UserFilesService());
    files.folders.addAll(const [
      GrantedFolder('content://docs/revoked', 'Revoked'),
      GrantedFolder('content://docs/read', 'Read only')
    ]);
    const channel = MethodChannel('com.neuromesh.ai/device');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'persistedFolders');
      return [
        {'uri': 'content://docs/read', 'read': true, 'write': false}
      ];
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await files.refreshGrants();
    expect(files.availableFolders.map((f) => f.name), ['Read only']);
    expect(agent.registry.find('read_user_file'), isNotNull);
    expect(agent.registry.find('write_user_file'), isNull);
    expect(agent.registry.find('export_file'), isNull);
  });

  test(
      'an approved action cannot start after cancellation or a superseding run',
      () async {
    final entered = Completer<void>();
    final approval = Completer<bool>();
    var generated = false;
    final pending = agent.runToolLoop(
        prompt: 'Write a file',
        history: [],
        confirm: (_, __, ___) {
          entered.complete();
          return approval.future;
        },
        onVisible: (_) {},
        onStatus: (_) {},
        cancelled: () => false,
        generate: (_, __, ___) async {
          if (generated) return 'done';
          generated = true;
          return call(
              'write_file', {'name': 'late.txt', 'content': 'must not write'});
        });
    await entered.future;
    agent.cancel();
    await run(['A new request superseded the action.']);
    approval.complete(true);
    final result = await pending;
    expect(result.answer, contains('Cancelled'));
    expect(await agent.dir.list().length, 0);
  });

  test('tool elapsed time comes from execution, not a fabricated zero',
      () async {
    agent.addTool(
        AgentTool('timed_probe', 'Measure real elapsed time', '{}', (_) async {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      return 'ok';
    }));
    final result = await run([call('timed_probe', {}), 'Done']);
    final step = jsonDecode(
        result.trace.single.substring(ToolLoopResult.traceMark.length));
    expect(step['ms'], greaterThanOrEqualTo(20));
  });

  test('duplicate discovery can recover without re-executing it', () async {
    final result = await run([
      call('search_tools', {'query': 'image'}),
      call('search_tools', {'query': 'image'}),
      call('generate_image', {'prompt': 'A blue and gray flying car'}),
      'Here is the generated car.'
    ]);
    expect(images.prompts, ['A blue and gray flying car']);
    expect(result.answer, contains('Here is'));
    expect(
        result.trace.join(), contains('duplicate discovery was not executed'));
  });

  test('a missing preferred clone returns an error without substituting audio',
      () async {
    await Get.find<HiveService>()
        .setSetting('voice_tts_id', 'pocket-tts-clone');
    final result = await agent.executeTool(
        const ParsedToolCall(
            'text_to_speech', {'text': 'Hello', 'name': 'hello.wav'}, ''),
        (_, __, ___) async => true);
    expect(result, contains('unavailable'));
    expect(await agent.dir.list().length, 0);
  });

  test('compact schemas retain property names and literal validation data',
      () async {
    final schema = <String, dynamic>{
      'type': 'object',
      'properties': {
        'description': {
          'type': 'string',
          'enum': ['literal ' * 40]
        },
        'default': {
          'type': 'string',
          'enum': ['one', 'two']
        }
      },
      'required': ['description', 'default'],
      'additionalProperties': false
    };
    agent.addTool(AgentTool(
        'compact_test', 'Compact schema fixture', '{}', (_) async => 'ok',
        schema: schema));
    await agent.executeTool(
        const ParsedToolCall('search_tools', {'query': 'compact_test'}, ''),
        (_, __, ___) async => true);
    final offered = agent
        .nativeSchemasForTurn(8192)
        .singleWhere((s) => s['function']['name'] == 'compact_test');
    expect(offered['function']['parameters'], schema);
  });

  test('core native tools are direct and other schemas expand after discovery',
      () async {
    final before = agent.nativeSchemasForTurn(2048);
    expect(before.map((s) => s['function']['name']), contains('search_tools'));
    expect(
        before.map((s) => s['function']['name']), contains('generate_image'));
    expect(
        before.map((s) => s['function']['name']), contains('text_to_speech'));
    await agent.executeTool(
        const ParsedToolCall('search_tools', {'query': 'calculator'}, ''),
        (_, __, ___) async => true);
    final after = agent.nativeSchemasForTurn(2048);
    expect(after.map((s) => s['function']['name']), contains('calculator'));
  });

  test(
      'unsupported schema assertions disable a tool instead of weakening validation',
      () async {
    var invoked = false;
    agent.addTool(AgentTool('unsupported', 'Requires a reference', '{}', (_) {
      invoked = true;
      return 'ok';
    }, schema: {
      'type': 'object',
      'properties': {
        'value': {r'$ref': '#/unknown'}
      }
    }));
    expect(agent.registry.find('unsupported'), isNull);
    expect(
        await agent.executeTool(
            const ParsedToolCall('unsupported', {'value': 'anything'}, ''),
            (_, __, ___) async => true),
        contains('Error:'));
    expect(invoked, isFalse);
  });

  test('all advertised built-ins have valid schemas', () {
    for (final tool in agent.registry.available) {
      expect(tool.inputSchema['type'], 'object', reason: tool.id);
      expect(tool.nativeSchema['function'], isA<Map>());
    }
    agent.internetAvailable = false;
    expect(agent.registry.find('generate_image'), isNull);
    expect(agent.registry.find('web_search'), isNull);
  });
}

class _DiskAgent extends AgentService {
  _DiskAgent(this.dir);
  final Directory dir;
  @override
  Future<Directory> filesDir() async => dir;
}

class _UnusedPlayer implements AudioPlayer {
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Voice extends VoiceService {
  _Voice() : super(player: _UnusedPlayer());
  @override
  bool get canSynthesizeFiles => true;
  @override
  Future<void> detectSystemFileTts() async {}
  @override
  Future<Uint8List> synthesizeToWav(String text,
      {String lang = '',
      bool allowWorker = true,
      String modelId = '',
      String speaker = ''}) async {
    expect(text, 'Astronomy studies stars and galaxies.');
    return encodeWav(Float32List.fromList([0, 0.1, -0.1, 0]), 16000);
  }
}

class _Images extends PollinationsImageService {
  final prompts = <String>[];
  @override
  Future<PollinationsImage> create(String prompt,
      {String? key, String style = '', dynamic client}) async {
    prompts.add(prompt);
    return (
      bytes: Uint8List.fromList(img.encodePng(img.Image(width: 2, height: 2))),
      model: 'mock-provider',
      extension: 'png'
    );
  }
}

class _Web extends WebSearchService {
  final queries = <String>[];
  @override
  Future<List<WebResult>> search(String query,
      {int max = 6, dynamic freshness}) async {
    queries.add(query);
    return [
      const WebResult('Mock discovery', 'https://example.com/discovery',
          'A mocked discovery.')
    ];
  }
}
