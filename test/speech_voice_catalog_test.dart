import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:neuromesh_ai/services/voice_service.dart';
import 'package:neuromesh_ai/services/voice_models.dart';
import 'package:neuromesh_ai/services/voice_clone_store.dart';
import 'package:neuromesh_ai/services/speech_voice_catalog.dart';

class _Models extends VoiceModelStore {
  @override
  // Skip production startup in this in-memory test double.
  // ignore: must_call_super
  void onInit() {}
}

class _UnusedPlayer implements AudioPlayer {
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Clones extends VoiceCloneStore {
  @override
  // Skip production startup in this in-memory test double.
  // ignore: must_call_super
  void onInit() {
    voices.addAll(['My voice', 'Invalid']);
  }

  @override
  Future<void> scan() async {}
  @override
  Future<({Float32List samples, int rate})?> load(String name) async =>
      name == 'My voice'
          ? (samples: Float32List.fromList([0, .25, 0]), rate: 16000)
          : null;
}

class _Voices extends VoiceService {
  _Voices() : super(player: _UnusedPlayer());
  String? chosen;
  @override
  Future<Uint8List> synthesizeClonedToWav(
      String text, Float32List reference, int rate) async {
    chosen = 'clone:$rate:${reference.length}';
    return encodeWav(reference, rate);
  }

  bool? worker;
  @override
  // Skip production startup in this in-memory test double.
  // ignore: must_call_super
  void onInit() {}

  @override
  Future<List<Map<String, String>>> availableSystemVoices() async => [
        {'name': 'Offline English', 'locale': 'en-US'},
        {'name': 'Offline Arabic', 'locale': 'ar'}
      ];
  @override
  Future<Uint8List> synthesizeToWav(String text,
      {String lang = '',
      bool allowWorker = true,
      String modelId = '',
      String speaker = ''}) async {
    chosen = '$modelId:$speaker';
    worker = allowWorker;
    return encodeWav(Float32List.fromList([0, .5, 0]), 16000);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Voices voices;
  setUp(() {
    Get.testMode = true;
    Get.put<VoiceModelStore>(_Models());
    voices = Get.put<VoiceService>(_Voices()) as _Voices;
  });
  tearDown(() async {
    await Get.delete<VoiceService>(force: true);
    Get.reset();
  });
  test('catalog contains only installed models and detected system voices',
      () async {
    final catalog = SpeechVoiceCatalog();
    var choices = await catalog.list(language: 'ar');
    expect(choices.map((v) => v.name), ['Offline Arabic']);
    Get.find<VoiceModelStore>().installed.add('piper-en-amy');
    choices = await catalog.list(language: 'en');
    expect(choices.any((v) => v.modelId == 'piper-en-amy'), true);
    expect(choices.any((v) => v.modelId == 'pocket-tts-clone'), false);
    expect(choices.every((v) => !v.toJson().containsKey('reference')), true);
  });
  test('only valid saved clones route to the local clone engine', () async {
    Get.put<VoiceCloneStore>(_Clones());
    final catalog = SpeechVoiceCatalog();
    expect(
        (await catalog.list()).where((v) => v.kind == 'saved_clone'), isEmpty);
    Get.find<VoiceModelStore>().installed.add('pocket-tts-clone');
    final clone =
        (await catalog.list()).singleWhere((v) => v.kind == 'saved_clone');
    expect(clone.id, 'clone:My%20voice');
    expect(clone.toJson().toString(), isNot(contains('samples')));
    await catalog.synthesize('Hello', clone.id);
    expect(voices.chosen, 'clone:16000:3');
    await expectLater(
        catalog.synthesize('Hello', 'clone:Invalid'), throwsArgumentError);
  });

  test('exact voice ID routes to selected offline voice without a worker',
      () async {
    final catalog = SpeechVoiceCatalog();
    final selected = (await catalog.list(language: 'en')).single;
    final wav = await catalog.synthesize('Hello', selected.id, language: 'en');
    expect(decodeWav(wav)?.samples.length, 3);
    expect(voices.chosen, 'system:Offline English');
    expect(voices.worker, false);
    await expectLater(catalog.synthesize('Hello', selected.id, language: 'ar'),
        throwsArgumentError);
    await expectLater(
        catalog.synthesize('Hello', 'unknown'), throwsArgumentError);
  });
}
