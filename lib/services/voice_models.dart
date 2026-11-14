import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

enum VoiceKind { stt, tts, vad }

class VoiceModelInfo {
  final String id;
  final VoiceKind kind;
  final String title;
  final String lang; // 'en', 'ar' or 'multi'
  final String archiveUrl;
  final String dirName; // folder inside the archive
  final String sizeLabel;
  /// espeak-ng voice used for Piper phonemization (TTS only).
  final String espeakVoice;
  /// True when [archiveUrl] is a single file (saved as silero_vad.onnx).
  final bool directFile;
  const VoiceModelInfo({
    required this.id,
    required this.kind,
    required this.title,
    required this.lang,
    required this.archiveUrl,
    required this.dirName,
    required this.sizeLabel,
    this.espeakVoice = '',
    this.directFile = false,
  });
}

const _asr = 'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models';
const _tts = 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models';

final kVoiceModels = <VoiceModelInfo>[
  VoiceModelInfo(
      id: 'whisper-tiny',
      kind: VoiceKind.stt,
      title: 'Whisper Tiny (fast, English + Arabic + 90 languages)',
      lang: 'multi',
      archiveUrl: '$_asr/sherpa-onnx-whisper-tiny.tar.bz2',
      dirName: 'sherpa-onnx-whisper-tiny',
      sizeLabel: '116 MB'),
  VoiceModelInfo(
      id: 'whisper-base',
      kind: VoiceKind.stt,
      title: 'Whisper Base (more accurate, slower)',
      lang: 'multi',
      archiveUrl: '$_asr/sherpa-onnx-whisper-base.tar.bz2',
      dirName: 'sherpa-onnx-whisper-base',
      sizeLabel: '208 MB'),
  VoiceModelInfo(
      id: 'piper-en-amy',
      kind: VoiceKind.tts,
      title: 'English voice (Amy)',
      lang: 'en',
      archiveUrl: '$_tts/vits-piper-en_US-amy-low.tar.bz2',
      dirName: 'vits-piper-en_US-amy-low',
      sizeLabel: '67 MB',
      espeakVoice: 'en-us'),
  VoiceModelInfo(
      id: 'piper-ar-kareem',
      kind: VoiceKind.tts,
      title: 'Arabic voice (Kareem)',
      lang: 'ar',
      archiveUrl: '$_tts/vits-piper-ar_JO-kareem-medium.tar.bz2',
      dirName: 'vits-piper-ar_JO-kareem-medium',
      sizeLabel: '67 MB',
      espeakVoice: 'ar'),
  VoiceModelInfo(
      id: 'silero-vad',
      kind: VoiceKind.vad,
      title: 'Smart speech detector (Silero)',
      lang: 'multi',
      archiveUrl: '$_asr/silero_vad.onnx',
      dirName: 'silero-vad',
      sizeLabel: '1 MB',
      directFile: true),
];

VoiceModelInfo? voiceModelById(String id) {
  for (final m in kVoiceModels) {
    if (m.id == id) return m;
  }
  return null;
}

/// Downloads, extracts and tracks voice models. They live in their own
/// folder so they never show up in the GGUF model library.
class VoiceModelStore extends GetxService {
  final installed = <String>{}.obs;
  final progress = <String, double>{}.obs; // 0..1, -1 = extracting
  final errors = <String, String>{}.obs;

  Future<Directory> _root() async {
    final base = await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}/voice_models');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<String> dirFor(VoiceModelInfo m) async =>
      '${(await _root()).path}/${m.dirName}';

  @override
  void onInit() {
    super.onInit();
    scan();
  }

  Future<void> scan() async {
    final s = <String>{};
    for (final m in kVoiceModels) {
      if (await Directory(await dirFor(m)).exists() &&
          await File('${await dirFor(m)}/.complete').exists()) {
        s.add(m.id);
      }
    }
    installed.assignAll(s);
  }

  Future<void> download(VoiceModelInfo m) async {
    if (progress.containsKey(m.id)) return;
    errors.remove(m.id);
    progress[m.id] = 0;
    final root = await _root();
    final tmp = File('${root.path}/${m.id}.tar.bz2');
    final client = http.Client();
    try {
      final req = http.Request('GET', Uri.parse(m.archiveUrl));
      final res = await client.send(req).timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) {
        throw Exception('Server answered ${res.statusCode}');
      }
      final total = res.contentLength ?? 0;
      var got = 0;
      final sink = tmp.openWrite();
      await for (final chunk in res.stream) {
        sink.add(chunk);
        got += chunk.length;
        if (total > 0) progress[m.id] = got / total;
      }
      await sink.close();
      if (m.directFile) {
        final dir = Directory('${root.path}/${m.dirName}');
        await dir.create(recursive: true);
        await tmp.rename('${dir.path}/silero_vad.onnx');
        await File('${dir.path}/.complete').writeAsString('ok');
        installed.add(m.id);
        return;
      }
      progress[m.id] = -1;
      final src = tmp.path;
      final dst = root.path;
      await Isolate.run(() => extractFileToDisk(src, dst));
      await File('${root.path}/${m.dirName}/.complete').writeAsString('ok');
      installed.add(m.id);
    } catch (e) {
      errors[m.id] = 'Download failed: $e';
    } finally {
      client.close();
      progress.remove(m.id);
      if (await tmp.exists()) await tmp.delete();
    }
  }

  Future<void> remove(VoiceModelInfo m) async {
    final d = Directory(await dirFor(m));
    if (await d.exists()) await d.delete(recursive: true);
    installed.remove(m.id);
  }
}
