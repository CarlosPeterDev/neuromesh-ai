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
  /// Zero-shot voice cloning: speaks in a voice learned from a short recording.
  final bool clone;

  /// Which runtime loads it: whisper, sensevoice, piper, kokoro, kitten,
  /// pocket or vad.
  final String engine;

  /// Names of the built-in voices, in the model's speaker order (multi-speaker
  /// models only). The user can audition them, so a wrong label is harmless.
  final List<String> speakers;

  int? speakerIndexFor(String name) {
    final query = name.trim().toLowerCase();
    if (query.isEmpty) return null;
    final exact = speakers.indexWhere((value) => value.toLowerCase() == query);
    if (exact >= 0) return exact;
    final matches = [
      for (var i = 0; i < speakers.length; i++)
        if (speakers[i].split(' (').first.toLowerCase() == query) i,
    ];
    return matches.length == 1 ? matches.single : null;
  }
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
    this.clone = false,
    this.engine = '',
    this.speakers = const [],
  });
}

const _asr = 'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models';
const _tts = 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models';

const _kokoroEn = [
  'Default (af)', 'Bella (F)', 'Nicole (F)', 'Sarah (F)', 'Sky (F)',
  'Adam (M)', 'Michael (M)', 'Emma (UK F)', 'Isabella (UK F)',
  'George (UK M)', 'Lewis (UK M)',
];

const _kokoroMulti = [
  'Alloy (F)', 'Aoede (F)', 'Bella (F)', 'Heart (F)', 'Jessica (F)',
  'Kore (F)', 'Nicole (F)', 'Nova (F)', 'River (F)', 'Sarah (F)', 'Sky (F)',
  'Adam (M)', 'Echo (M)', 'Eric (M)', 'Fenrir (M)', 'Liam (M)',
  'Michael (M)', 'Onyx (M)', 'Puck (M)', 'Santa (M)',
  'Alice (UK F)', 'Emma (UK F)', 'Isabella (UK F)', 'Lily (UK F)',
  'Daniel (UK M)', 'Fable (UK M)', 'George (UK M)', 'Lewis (UK M)',
  'Dora (ES F)', 'Alex (ES M)', 'Siwis (FR F)',
  'Alpha (HI F)', 'Beta (HI F)', 'Omega (HI M)', 'Psi (HI M)',
  'Sara (IT F)', 'Nicola (IT M)',
  'Alpha (JA F)', 'Gongitsune (JA F)', 'Nezumi (JA F)', 'Tebukuro (JA F)', 'Kumo (JA M)',
  'Dora (PT F)', 'Alex (PT M)', 'Santa (PT M)',
  'Xiaobei (ZH F)', 'Xiaoni (ZH F)', 'Xiaoxiao (ZH F)', 'Xiaoyi (ZH F)',
  'Yunjian (ZH M)', 'Yunxi (ZH M)', 'Yunxia (ZH M)', 'Yunyang (ZH M)',
];

const _kittenVoices = [
  'Voice 2 (M)', 'Voice 2 (F)', 'Voice 3 (M)', 'Voice 3 (F)',
  'Voice 4 (M)', 'Voice 4 (F)', 'Voice 5 (M)', 'Voice 5 (F)',
];

VoiceModelInfo _piper(String id, String title, String lang, String espeak,
        String dir, String size) =>
    VoiceModelInfo(
        id: id,
        kind: VoiceKind.tts,
        title: title,
        lang: lang,
        archiveUrl: '$_tts/$dir.tar.bz2',
        dirName: dir,
        sizeLabel: size,
        espeakVoice: espeak,
        engine: 'piper');

final kVoiceModels = <VoiceModelInfo>[
  // ── Listening ──
  VoiceModelInfo(
      id: 'whisper-tiny',
      kind: VoiceKind.stt,
      title: 'Whisper Tiny (fast, 90+ languages incl. Arabic)',
      lang: 'multi',
      archiveUrl: '$_asr/sherpa-onnx-whisper-tiny.tar.bz2',
      dirName: 'sherpa-onnx-whisper-tiny',
      sizeLabel: '116 MB',
      engine: 'whisper'),
  VoiceModelInfo(
      id: 'whisper-base',
      kind: VoiceKind.stt,
      title: 'Whisper Base (more accurate, 90+ languages)',
      lang: 'multi',
      archiveUrl: '$_asr/sherpa-onnx-whisper-base.tar.bz2',
      dirName: 'sherpa-onnx-whisper-base',
      sizeLabel: '208 MB',
      engine: 'whisper'),
  VoiceModelInfo(
      id: 'whisper-small',
      kind: VoiceKind.stt,
      title: 'Whisper Small (accurate, 90+ languages, needs 4 GB+ RAM)',
      lang: 'multi',
      archiveUrl: '$_asr/sherpa-onnx-whisper-small.tar.bz2',
      dirName: 'sherpa-onnx-whisper-small',
      sizeLabel: '610 MB',
      engine: 'whisper'),
  VoiceModelInfo(
      id: 'whisper-turbo',
      kind: VoiceKind.stt,
      title: 'Whisper Turbo (best accuracy, 90+ languages, needs 6 GB+ RAM)',
      lang: 'multi',
      archiveUrl: '$_asr/sherpa-onnx-whisper-turbo.tar.bz2',
      dirName: 'sherpa-onnx-whisper-turbo',
      sizeLabel: '538 MB',
      engine: 'whisper'),
  VoiceModelInfo(
      id: 'sensevoice',
      kind: VoiceKind.stt,
      title: 'SenseVoice (fast; Chinese, English, Japanese, Korean, Cantonese)',
      lang: 'multi',
      archiveUrl: '$_asr/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09.tar.bz2',
      dirName: 'sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09',
      sizeLabel: '158 MB',
      engine: 'sensevoice'),

  // ── Speaking: English ──
  VoiceModelInfo(
      id: 'piper-en-amy',
      kind: VoiceKind.tts,
      title: 'English: Amy (female, light)',
      lang: 'en',
      archiveUrl: '$_tts/vits-piper-en_US-amy-low.tar.bz2',
      dirName: 'vits-piper-en_US-amy-low',
      sizeLabel: '67 MB',
      espeakVoice: 'en-us',
      engine: 'piper'),
  _piper('piper-en-lessac', 'English: Lessac (female, natural)', 'en', 'en-us',
      'vits-piper-en_US-lessac-medium', '64 MB'),
  _piper('piper-en-ryan', 'English: Ryan (male, natural)', 'en', 'en-us',
      'vits-piper-en_US-ryan-medium', '64 MB'),
  _piper('piper-en-joe', 'English: Joe (male)', 'en', 'en-us',
      'vits-piper-en_US-joe-medium', '64 MB'),
  _piper('piper-en-hfc-f', 'English: HFC (female)', 'en', 'en-us',
      'vits-piper-en_US-hfc_female-medium', '64 MB'),
  VoiceModelInfo(
      id: 'kokoro-en',
      kind: VoiceKind.tts,
      title: 'English: Kokoro (11 high-quality voices)',
      lang: 'en',
      archiveUrl: '$_tts/kokoro-int8-en-v0_19.tar.bz2',
      dirName: 'kokoro-int8-en-v0_19',
      sizeLabel: '99 MB',
      engine: 'kokoro',
      speakers: _kokoroEn),
  VoiceModelInfo(
      id: 'kokoro-multi',
      kind: VoiceKind.tts,
      title: 'Kokoro multilingual (53 voices: English, Chinese, French, Hindi, Italian, Japanese, Portuguese, Spanish)',
      lang: 'multi',
      archiveUrl: '$_tts/kokoro-int8-multi-lang-v1_0.tar.bz2',
      dirName: 'kokoro-int8-multi-lang-v1_0',
      sizeLabel: '126 MB',
      engine: 'kokoro',
      speakers: _kokoroMulti),
  VoiceModelInfo(
      id: 'kitten-nano',
      kind: VoiceKind.tts,
      title: 'English: Kitten Nano (tiny, 8 voices)',
      lang: 'en',
      archiveUrl: '$_tts/kitten-nano-en-v0_8-int8.tar.bz2',
      dirName: 'kitten-nano-en-v0_8-int8',
      sizeLabel: '30 MB',
      engine: 'kitten',
      speakers: _kittenVoices),

  // ── Speaking: Arabic ──
  VoiceModelInfo(
      id: 'piper-ar-kareem',
      kind: VoiceKind.tts,
      title: 'Arabic: Kareem (male)',
      lang: 'ar',
      archiveUrl: '$_tts/vits-piper-ar_JO-kareem-medium.tar.bz2',
      dirName: 'vits-piper-ar_JO-kareem-medium',
      sizeLabel: '67 MB',
      espeakVoice: 'ar',
      engine: 'piper'),
  _piper('piper-ar-miro2', 'Arabic: Miro V2 (high quality)', 'ar', 'ar',
      'vits-piper-ar_JO-SA_miro_V2-high', '64 MB'),
  _piper('piper-ar-dii', 'Arabic: Dii (high quality)', 'ar', 'ar',
      'vits-piper-ar_JO-SA_dii-high', '64 MB'),

  // ── Speaking: other languages ──
  _piper('piper-fr', 'French: Siwis', 'fr', 'fr', 'vits-piper-fr_FR-siwis-medium', '64 MB'),
  _piper('piper-es', 'Spanish: DaveFX', 'es', 'es', 'vits-piper-es_ES-davefx-medium', '64 MB'),
  _piper('piper-de', 'German: Thorsten', 'de', 'de', 'vits-piper-de_DE-thorsten-medium', '64 MB'),
  _piper('piper-ru', 'Russian: Ruslan', 'ru', 'ru', 'vits-piper-ru_RU-ruslan-medium', '64 MB'),
  _piper('piper-tr', 'Turkish: Fahrettin', 'tr', 'tr', 'vits-piper-tr_TR-fahrettin-medium', '64 MB'),
  _piper('piper-hi', 'Hindi: Pratham', 'hi', 'hi', 'vits-piper-hi_IN-pratham-medium', '64 MB'),
  _piper('piper-pt', 'Portuguese (BR): Faber', 'pt', 'pt-br', 'vits-piper-pt_BR-faber-medium', '64 MB'),
  _piper('piper-it', 'Italian: Paola', 'it', 'it', 'vits-piper-it_IT-paola-medium', '64 MB'),

  // ── Voice cloning ──
  VoiceModelInfo(
      id: 'pocket-tts-clone',
      kind: VoiceKind.tts,
      title: 'Voice cloning (English, Pocket TTS)',
      lang: 'en',
      archiveUrl: '$_tts/sherpa-onnx-pocket-tts-int8-2026-01-26.tar.bz2',
      dirName: 'sherpa-onnx-pocket-tts-int8-2026-01-26',
      sizeLabel: '98 MB',
      clone: true,
      engine: 'pocket'),

  // ── Turn-taking ──
  VoiceModelInfo(
      id: 'silero-vad',
      kind: VoiceKind.vad,
      title: 'Smart speech detector (Silero)',
      lang: 'multi',
      archiveUrl: '$_asr/silero_vad.onnx',
      dirName: 'silero-vad',
      sizeLabel: '1 MB',
      directFile: true,
      engine: 'vad'),
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
  final _cancelled = <String>{};
  final _clients = <String, http.Client>{};

  /// Stops a download in progress and removes the partial file.
  void cancel(String id) {
    if (!progress.containsKey(id)) return;
    _cancelled.add(id);
    _clients[id]?.close();
  }

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
    _clients[m.id] = client;
    _cancelled.remove(m.id);
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
        if (_cancelled.contains(m.id)) throw Exception('cancelled');
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
      if (_cancelled.contains(m.id)) throw Exception('cancelled');
      progress[m.id] = -1;
      final src = tmp.path;
      final dst = root.path;
      await Isolate.run(() => extractFileToDisk(src, dst));
      await File('${root.path}/${m.dirName}/.complete').writeAsString('ok');
      installed.add(m.id);
    } catch (e) {
      if (!_cancelled.contains(m.id)) errors[m.id] = 'Download failed: $e';
    } finally {
      _clients.remove(m.id);
      _cancelled.remove(m.id);
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
