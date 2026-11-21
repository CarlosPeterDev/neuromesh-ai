import 'dart:typed_data';
import 'package:get/get.dart';
import 'voice_service.dart';
import 'voice_models.dart';
import 'voice_clone_store.dart';

class SpeechVoiceChoice {
  const SpeechVoiceChoice(
      {required this.id,
      required this.name,
      required this.language,
      required this.kind,
      this.modelId = '',
      this.speaker = '',
      this.cloneName = ''});
  final String id, name, language, kind, modelId, speaker, cloneName;
  Map<String, String> toJson() => {
        'voice_id': id,
        'name': name,
        'language': language,
        'kind': kind,
        if (modelId.isNotEmpty) 'model_id': modelId
      };
}

/// Only installed/local voices are exposed. Clone reference bytes and file
/// paths never enter the model's catalog or leave this device.
class SpeechVoiceCatalog {
  bool get hasClone =>
      Get.isRegistered<VoiceCloneStore>() &&
      Get.find<VoiceCloneStore>().voices.isNotEmpty &&
      Get.isRegistered<VoiceModelStore>() &&
      Get.find<VoiceModelStore>().installed.contains('pocket-tts-clone');

  Future<List<SpeechVoiceChoice>> list({String language = ''}) async {
    final result = <SpeechVoiceChoice>[];
    if (Get.isRegistered<VoiceModelStore>()) {
      final installed = Get.find<VoiceModelStore>().installed;
      for (final model in kVoiceModels.where((m) =>
          m.kind == VoiceKind.tts && !m.clone && installed.contains(m.id))) {
        if (model.speakers.isEmpty) {
          result.add(SpeechVoiceChoice(
              id: 'model:${model.id}',
              name: model.title,
              language: model.lang,
              kind: 'local',
              modelId: model.id));
        } else {
          for (final speaker in model.speakers) {
            result.add(SpeechVoiceChoice(
                id: 'model:${model.id}:${Uri.encodeComponent(speaker)}',
                name: '${model.title} — $speaker',
                language: model.lang,
                kind: 'local',
                modelId: model.id,
                speaker: speaker));
          }
        }
      }
    }
    if (Get.isRegistered<VoiceCloneStore>()) {
      final clones = Get.find<VoiceCloneStore>();
      await clones.scan();
      if (hasClone)
        for (final name in clones.voices) {
          final reference = await clones.load(name);
          if (reference == null || reference.samples.isEmpty) continue;
          result.add(SpeechVoiceChoice(
              id: 'clone:${Uri.encodeComponent(name)}',
              name: name,
              language: 'en',
              kind: 'saved_clone',
              modelId: 'pocket-tts-clone',
              cloneName: name));
        }
    }
    if (Get.isRegistered<VoiceService>()) {
      for (final voice
          in await Get.find<VoiceService>().availableSystemVoices()) {
        final name = voice['name']!, locale = voice['locale']!;
        result.add(SpeechVoiceChoice(
            id: 'system:${Uri.encodeComponent(locale)}:${Uri.encodeComponent(name)}',
            name: name,
            language: locale,
            kind: 'system_offline',
            modelId: 'system',
            speaker: name));
      }
    }
    final lang =
        language.trim().toLowerCase().replaceAll('_', '-').split('-').first;
    return result
        .where((v) =>
            lang.isEmpty ||
            v.language == 'multi' ||
            v.language.toLowerCase().replaceAll('_', '-').split('-').first ==
                lang)
        .toList();
  }

  String? get selectedCloneId {
    if (!hasClone || !Get.isRegistered<VoiceModelStore>()) return null;
    final clone = Get.find<VoiceCloneStore>().active.value;
    return clone.isEmpty ? null : 'clone:${Uri.encodeComponent(clone)}';
  }

  Future<Uint8List> synthesize(String text, String id,
      {String language = ''}) async {
    final choices = await list(language: language);
    final voice = choices.firstWhereOrNull((v) => v.id == id);
    if (voice == null)
      throw ArgumentError(
          'Voice is unavailable or does not match the requested language. Call list_voices again.');
    final service = Get.find<VoiceService>();
    if (voice.kind == 'saved_clone') {
      final reference = await Get.find<VoiceCloneStore>().load(voice.cloneName);
      if (reference == null)
        throw StateError('The saved voice reference is missing.');
      return service.synthesizeClonedToWav(
          text, reference.samples, reference.rate);
    }
    return service.synthesizeToWav(text,
        lang: language.isEmpty ? voice.language : language,
        modelId: voice.modelId,
        speaker: voice.speaker,
        allowWorker: false);
  }
}
