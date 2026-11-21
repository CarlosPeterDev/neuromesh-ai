// Device-only tests. Run against a dedicated test installation with a folder
// already granted through NeuroMesh's Android folder picker. Never supply an
// arbitrary content URI without first obtaining its persisted permission.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';
import 'package:neuromesh_ai/services/hive_service.dart';
import 'package:neuromesh_ai/services/user_files.dart';
import 'package:neuromesh_ai/services/voice_service.dart';
import 'package:neuromesh_ai/services/inference_android.dart';
import 'package:neuromesh_ai/services/tool_registry.dart';
import 'package:neuromesh_ai/services/agent_tools.dart';
import 'dart:convert';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const tree = String.fromEnvironment('NEUROMESH_TEST_TREE_URI');
  const model = String.fromEnvironment('NEUROMESH_TEST_GGUF_PATH');
  late Directory temp;
  setUp(() async {
    temp = await (await getTemporaryDirectory())
        .createTemp('native-verification-');
    Hive.init(temp.path);
    Get.put(await HiveService().init());
  });
  tearDown(() async {
    Get.reset();
    await Hive.close();
    await temp.delete(recursive: true);
  });

  testWidgets(
      'real SAF nested creation, read-back, append, rename and deletion',
      (tester) async {
    final service = Get.put(UserFilesService());
    const folder = GrantedFolder(tree, 'Device test folder');
    final stem = 'neuromesh-test-${DateTime.now().microsecondsSinceEpoch}';
    await service.mutateFile(folder, stem, 'mkdir');
    final path = '$stem/unicode.txt';
    await service.writeText(folder, path, 'Astronomy 🌌');
    expect(await service.readText(folder, path, requireComplete: true),
        'Astronomy 🌌');
    await service.mutateFile(folder, path, 'append', content: '\nVerified');
    expect(await service.readText(folder, path, requireComplete: true),
        'Astronomy 🌌\nVerified');
    expect(await service.fileUri(folder, path), startsWith('content://'));
    await service.mutateFile(folder, path, 'rename', newName: 'renamed.txt');
    expect((await service.list(folder, stem)).single.name, 'renamed.txt');
    await service.mutateFile(folder, '$stem/renamed.txt', 'delete');
    expect(await service.list(folder, stem), isEmpty);
  }, skip: !Platform.isAndroid || tree.isEmpty);

  testWidgets('real Android system TTS creates a readable nonempty WAV',
      (tester) async {
    final voice = Get.put(VoiceService());
    await voice.detectSystemFileTts();
    expect(voice.systemFileTtsAvailable.value, isTrue,
        reason: 'Install an offline Android TTS voice on the test device.');
    final bytes =
        await voice.synthesizeToWav('Astronomy studies the stars.', lang: 'en');
    final file = File('${temp.path}/speech.wav');
    await file.writeAsBytes(bytes, flush: true);
    expect(decodeWav(await file.readAsBytes())?.samples, isNotEmpty);
  }, skip: !Platform.isAndroid);

  testWidgets('same compatible GGUF honors enabled and disabled thinking',
      (tester) async {
    final engine = InferenceEngine();
    final loaded = await engine.loadModel(
        modelPath: model,
        contextSize: 2048,
        deviceTier: 'mid',
        allowGgufGpu: false);
    expect(loaded.success, isTrue);
    expect(loaded.supportsThinking, isTrue);
    try {
      final results = <String>[];
      for (final thinking in [false, true]) {
        results.add(await engine.generate(
            prompt: 'What is 12 times 13? Answer briefly.',
            systemPrompt: 'You are a helpful assistant.',
            modelName: 'same test model',
            maxTokens: 384,
            temperature: 0,
            normalThinking: thinking,
            onToken: (_) {}));
      }
      expect(results[0], contains('156'));
      expect(results[1], contains('156'));
      expect(results[0], isNot(contains('</think>')));
      expect(results[1], contains('</think>'));
    } finally {
      await engine.dispose();
    }
  }, skip: !Platform.isAndroid || model.isEmpty);
  testWidgets('native GGUF tool schemas, parsing and result history on Android',
      (tester) async {
    final engine = InferenceEngine();
    final loaded = await engine.loadModel(
        modelPath: model,
        contextSize: 2048,
        deviceTier: 'mid',
        allowGgufGpu: false);
    expect(loaded.success, isTrue);
    expect(loaded.supportsToolSchema, isTrue);
    final tools = [
      {
        'type': 'function',
        'function': {
          'name': 'calculator',
          'description': 'Calculate exactly',
          'parameters': {
            'type': 'object',
            'properties': {
              'expression': {'type': 'string'}
            },
            'required': ['expression']
          }
        }
      }
    ];
    const request = 'Use the calculator to calculate 17*19.';
    try {
      final response = await engine.generate(
          prompt: request,
          systemPrompt: 'Use tools where needed.',
          modelName: 'test GGUF',
          maxTokens: 384,
          temperature: 0,
          nativeTools: tools,
          onToken: (_) {});
      final selected = decodeModelCalls(response).single;
      expect(selected.name, 'calculator');
      final value = formatNumber(
          evaluateExpression(selected.arguments['expression'] as String));
      final call =
          ModelToolCall(selected.name, selected.arguments, id: 'step_1');
      final result = jsonEncode({
        'untrusted': true,
        'tool_results': [
          {
            'id': 'step_1',
            'name': selected.name,
            'status': 'ok',
            'content': value
          }
        ]
      });
      final answer = await engine.generate(
          prompt: result,
          conversationHistory: [
            {'role': 'user', 'content': request},
            {
              'role': 'assistant',
              'content': encodeModelCalls([call]),
              '_nm_tools': 'true'
            },
            {'role': 'user', 'content': result}
          ],
          systemPrompt: 'Answer using the tool result.',
          modelName: 'test GGUF',
          maxTokens: 384,
          temperature: 0,
          nativeTools: tools,
          onToken: (_) {});
      expect(answer, contains('323'));
      expect(decodeModelCalls(answer), isEmpty);
    } finally {
      await engine.dispose();
    }
  }, skip: !Platform.isAndroid || model.isEmpty);
}
