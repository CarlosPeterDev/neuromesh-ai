import 'package:neuromesh_ai/services/chat_calculator.dart';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:neuromesh_ai/services/chat_tool_service.dart';
import 'package:neuromesh_ai/services/hive_service.dart';
import 'package:neuromesh_ai/services/voice_models.dart';
import 'package:neuromesh_ai/services/voice_service.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.root, this.support);
  final String root;
  final String support;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getTemporaryPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => support;
}

class _TestModels extends VoiceModelStore {
  _TestModels(this.root, this.model);
  final String root;
  final VoiceModelInfo model;

  @override
  Future<void> scan() async {
    installed.add(model.id);
  }

  @override
  Future<String> dirFor(VoiceModelInfo model) async => '$root/${model.dirName}';
}

class _UnusedPlayer implements AudioPlayer {
  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final root = Platform.environment['NEUROMESH_TEST_VOICE_MODELS'];
  late Directory support;
  setUpAll(() async {
    support = await Directory.systemTemp.createTemp('voice-phonemizer-');
  });
  tearDownAll(() => support.delete(recursive: true));

  for (final id in ['kitten-nano', 'kokoro-en']) {
    final model = voiceModelById(id)!;
    test('${model.title} produces a WAV through the app TTS tool', () async {
      final dir = await Directory.systemTemp.createTemp('voice-model-test-');
      final previous = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _TestPaths(dir.path, support.path);
      Hive.init(dir.path);
      addTearDown(() async {
        await Get.delete<VoiceService>(force: true);
        Get.reset();
        await Hive.close();
        PathProviderPlatform.instance = previous;
        await dir.delete(recursive: true);
      });
      Get.put(await HiveService().init());
      Get.put<VoiceModelStore>(_TestModels(root!, model));
      Get.put(VoiceService(player: _UnusedPlayer()));
      final agent = ChatToolService();
      final reportedCall = id == 'kitten-nano';
      if (reportedCall) {
        await Get.find<HiveService>().setSetting('voice_speaker_$id', 1);
      }
      final result = await agent.executeTool(
          ParsedToolCall(
              'text_to_speech',
              {
                'text': reportedCall
                    ? 'Hello, Carlos!'
                    : 'Playing sports builds fitness and teaches teamwork.',
                if (reportedCall) ...{
                  'model_id': 'tts-1',
                  'speaker': 'male',
                  'language': 'en-US',
                },
              },
              ''),
          (_, __, ___) async => false);

      final name = RegExp(r'nmfile:([^)]+)').firstMatch(result)?.group(1);
      expect(name, isNotNull, reason: result);
      final file = await agent.workspaceFile(name!);
      expect(file, isNotNull, reason: result);
      final wav = decodeWav(await file!.readAsBytes());
      expect(wav, isNotNull);
      expect(wav!.samples.length,
          greaterThan(wav.rate * (reportedCall ? 0.3 : 2)));
      expect(wav.samples.any((sample) => sample.abs() > 0.05), isTrue);
      if (reportedCall) {
        expect(result, contains('Voice: Voice 2 (M) · kitten-nano'));
        expect(VoiceService.savedSpeaker(model), 1);
        await expectLater(
          Get.find<VoiceService>().synthesizeToWav(
            'Hello',
            lang: 'fr-FR',
            voice: 'male',
          ),
          throwsA(isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('No matching male fr voice'),
          )),
        );
      }
    },
        skip: root == null
            ? 'Download the two voice model fixtures to run.'
            : null);
  }
}
