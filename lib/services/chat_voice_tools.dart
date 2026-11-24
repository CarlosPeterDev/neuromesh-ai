import 'package:get/get.dart';

import '../controllers/model_controller.dart';
import '../utils/model_file_role.dart';
import 'chat_tool_service.dart';
import 'voice_models.dart';
import 'voice_service.dart';

/// Reports installed speech models and speakers.
void registerVoiceModelStatus(ChatToolService agent) {
  agent.addTool(ChatTool(
    'models_status',
    'Show which AI models are installed and ready: chat models, listening (speech to text) and speaking (text to speech). Use this to check voice choices for text_to_speech and transcribe_audio.',
    '{}',
    (args) async {
      final mc = Get.find<ModelController>();
      final vs = Get.find<VoiceModelStore>();
      final v = Get.find<VoiceService>();
      final b = StringBuffer();
      b.writeln(
          'Chat model loaded now: ${mc.lastLoadedModelName.isEmpty ? '(none)' : mc.lastLoadedModelName}');
      final files = mc.downloadedFiles.toList();
      for (final file in files.take(30)) {
        b.writeln('$file — ${modelFileRole(file).label}');
      }
      b.writeln(
          'Downloaded models (${files.length}): ${files.isEmpty ? 'none' : files.take(30).join(', ')}');
      final voiceModels = kVoiceModels
          .where((m) => !m.clone && vs.installed.contains(m.id))
          .toList();
      for (final (kind, heading, loaded) in [
        (VoiceKind.stt, 'Listening models', v.sttReady),
        (VoiceKind.tts, 'Speaking models', v.ttsReady),
      ]) {
        final entries = voiceModels.where((m) => m.kind == kind).map((m) =>
            '${m.id} — ${m.title} [${m.lang}]${m.speakers.isEmpty ? '' : '; speakers: ${m.speakers.join(', ')}'}');
        b.writeln(
            '$heading: ${entries.isEmpty ? 'NONE (download in Models → Voice)' : entries.join('\n')}${loaded ? '\nRuntime loaded' : ''}');
      }
      b.writeln('Image generation: Pollinations online (internet required).');
      return b.toString().trim();
    },
  ));
}
