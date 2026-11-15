import 'dart:async';
import 'dart:math' as math;
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:piper_phonemize/piper_phonemize.dart' as piper;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'hive_service.dart';
import 'voice_models.dart';

/// Pure helper: float samples in [-1,1] to a 16-bit mono WAV file body.
Uint8List encodeWav(Float32List samples, int sampleRate) {
  final data = ByteData(44 + samples.length * 2);
  void str(int o, String s) {
    for (var i = 0; i < s.length; i++) {
      data.setUint8(o + i, s.codeUnitAt(i));
    }
  }

  str(0, 'RIFF');
  data.setUint32(4, 36 + samples.length * 2, Endian.little);
  str(8, 'WAVE');
  str(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, sampleRate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  str(36, 'data');
  data.setUint32(40, samples.length * 2, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    final v = (samples[i].clamp(-1.0, 1.0) * 32767).round();
    data.setInt16(44 + i * 2, v, Endian.little);
  }
  return data.buffer.asUint8List();
}

/// Reads a PCM WAV (8/16-bit, any channel count; first channel is used).
/// Returns null if the bytes aren't a supported WAV.
({Float32List samples, int rate})? decodeWav(Uint8List b) {
  if (b.length < 44) return null;
  final bd = ByteData.sublistView(b);
  String tag(int o) => String.fromCharCodes(b.sublist(o, o + 4));
  if (tag(0) != 'RIFF' || tag(8) != 'WAVE') return null;
  var pos = 12;
  int rate = 0, channels = 1, bits = 16, fmt = 1;
  while (pos + 8 <= b.length) {
    final id = tag(pos);
    final size = bd.getUint32(pos + 4, Endian.little);
    final body = pos + 8;
    if (id == 'fmt ') {
      fmt = bd.getUint16(body, Endian.little);
      channels = bd.getUint16(body + 2, Endian.little);
      rate = bd.getUint32(body + 4, Endian.little);
      bits = bd.getUint16(body + 14, Endian.little);
    } else if (id == 'data') {
      if (fmt != 1 || channels < 1 || rate <= 0 || (bits != 16 && bits != 8)) {
        return null;
      }
      final avail = math.min(size, b.length - body);
      final bytes = bits ~/ 8;
      final frames = avail ~/ (bytes * channels);
      final out = Float32List(frames);
      for (var i = 0; i < frames; i++) {
        final o = body + i * bytes * channels;
        out[i] = bits == 16
            ? bd.getInt16(o, Endian.little) / 32768.0
            : (b[o] - 128) / 128.0;
      }
      return (samples: out, rate: rate);
    }
    pos = body + size + (size.isOdd ? 1 : 0);
  }
  return null;
}

/// Splits text into short speakable chunks and removes markdown noise.
List<String> speechChunks(String text) {
  var t = text
      .replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '')
      .replaceAll(RegExp(r'```[\s\S]*?```'), ' ')
      .replaceAll(RegExp(r'[*_#`>~]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (t.isEmpty) return [];
  final parts = t.split(RegExp(r'(?<=[.!?؟。])\s+'));
  return parts.where((p) => p.trim().isNotEmpty).toList();
}

/// Streaming helper: from the reply text produced so far, returns the
/// sentences that are complete since [from] and the new read position.
/// Text inside <think>…</think> (even unfinished) is never spoken.
({List<String> sentences, int next, String visible}) nextSentences(
    String raw, int from,
    {bool flush = false}) {
  var visible = raw.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '');
  final open = visible.indexOf('<think>');
  if (open >= 0) visible = visible.substring(0, open);
  if (from > visible.length) from = visible.length;
  final out = <String>[];
  var pos = from;
  final re = RegExp(r'[.!?؟。\n]+(\s+|$)');
  for (final m in re.allMatches(visible.substring(from))) {
    final end = from + m.end;
    // A trailing '.' at the very end may be a decimal point still being typed.
    if (!flush && m.end == visible.length - from && !m.group(0)!.endsWith(' ') &&
        !m.group(0)!.contains('\n')) {
      break;
    }
    final piece = visible.substring(pos, end).trim();
    if (piece.length >= 8 || (flush && piece.isNotEmpty)) {
      out.add(piece);
      pos = end;
    }
  }
  if (flush && pos < visible.length) {
    final rest = visible.substring(pos).trim();
    if (rest.isNotEmpty) out.add(rest);
    pos = visible.length;
  }
  return (sentences: out, next: pos, visible: visible);
}

class VoiceService extends GetxService {
  sherpa.OfflineRecognizer? _stt;
  String? _sttId;
  sherpa.OfflineTts? _tts;
  String? _ttsId;
  String _espeak = '';
  bool _bindings = false;
  bool _phonemizerReady = false;

  final AudioPlayer _player = AudioPlayer();
  FlutterTts? _system;
  bool _stopSpeaking = false;
  bool _isClone = false;
  Float32List? _cloneRef;
  int _cloneRate = 0;

  /// A stronger phone on the Wi-Fi that does the speaking for this one.
  String workerUrl = '';
  String workerToken = '';

  bool get cloneLoaded => _isClone && _tts != null;
  bool get hasCloneVoice => _cloneRef != null;

  void setCloneVoice(Float32List samples, int rate) {
    _cloneRef = samples;
    _cloneRate = rate;
  }

  void loadWorkerSettings() {
    final h = Get.find<HiveService>();
    workerUrl = h.getSetting<String>('voice_worker_url') ?? '';
    workerToken = h.getSetting<String>('voice_worker_token') ?? '';
  }

  /// Creates a Silero voice-activity detector, or null if it isn't installed.
  Future<sherpa.VoiceActivityDetector?> createVad() async {
    final store = Get.find<VoiceModelStore>();
    final m = voiceModelById('silero-vad');
    if (m == null || !store.installed.contains(m.id)) return null;
    _initBindings();
    final path = '${await store.dirFor(m)}/silero_vad.onnx';
    if (!File(path).existsSync()) return null;
    return sherpa.VoiceActivityDetector(
      config: sherpa.VadModelConfig(
        sileroVad: sherpa.SileroVadModelConfig(
            model: path,
            threshold: 0.5,
            minSilenceDuration: 0.8,
            minSpeechDuration: 0.3,
            windowSize: 512,
            maxSpeechDuration: 15),
        sampleRate: 16000,
        numThreads: 1,
        debug: false,
      ),
      bufferSizeInSeconds: 30,
    );
  }

  bool get sttReady => _stt != null;
  bool get ttsReady => _tts != null;

  void _initBindings() {
    if (_bindings) return;
    sherpa.initBindings();
    _bindings = true;
  }

  Future<String> _firstFile(String dir, bool Function(String) test) async {
    final files = Directory(dir)
        .listSync()
        .whereType<File>()
        .map((f) => f.path)
        .where(test)
        .toList()
      ..sort();
    if (files.isEmpty) throw Exception('Model files missing in $dir');
    return files.first;
  }

  Future<void> loadStt(VoiceModelInfo m, {String language = ''}) async {
    _initBindings();
    final dir = await Get.find<VoiceModelStore>().dirFor(m);
    final enc = await _firstFile(dir, (p) => p.contains('encoder') && p.endsWith('.int8.onnx'))
        .catchError((_) => _firstFile(dir, (p) => p.contains('encoder') && p.endsWith('.onnx')));
    final dec = await _firstFile(dir, (p) => p.contains('decoder') && p.endsWith('.int8.onnx'))
        .catchError((_) => _firstFile(dir, (p) => p.contains('decoder') && p.endsWith('.onnx')));
    final tokens = await _firstFile(dir, (p) => p.endsWith('tokens.txt'));
    final cfg = sherpa.OfflineRecognizerConfig(
      model: sherpa.OfflineModelConfig(
        whisper: sherpa.OfflineWhisperModelConfig(
            encoder: enc, decoder: dec, language: language, task: 'transcribe'),
        tokens: tokens,
        numThreads: 2,
        debug: false,
      ),
    );
    _stt?.free();
    _stt = await sherpa.OfflineRecognizer.createAsync(cfg);
    _sttId = '${m.id}|$language';
  }

  bool sttLoadedFor(VoiceModelInfo m, String language) =>
      _stt != null && _sttId == '${m.id}|$language';

  Future<void> loadTts(VoiceModelInfo m) async {
    _initBindings();
    final dir = await Get.find<VoiceModelStore>().dirFor(m);
    if (m.clone) {
      Future<String> f(String part, String ext) =>
          _firstFile(dir, (p) => p.split('/').last.contains(part) && p.endsWith(ext));
      final cfg = sherpa.OfflineTtsConfig(
        model: sherpa.OfflineTtsModelConfig(
          pocket: sherpa.OfflineTtsPocketModelConfig(
            lmFlow: await f('lm_flow', '.onnx'),
            lmMain: await f('lm_main', '.onnx'),
            encoder: await f('encoder', '.onnx'),
            decoder: await f('decoder', '.onnx'),
            textConditioner: await f('text_conditioner', '.onnx'),
            vocabJson: await f('vocab', '.json'),
            tokenScoresJson: await f('token_scores', '.json'),
          ),
          numThreads: 4,
          debug: false,
        ),
        maxNumSentences: 1,
      );
      _tts?.free();
      _tts = sherpa.OfflineTts(cfg);
      _ttsId = m.id;
      _isClone = true;
      return;
    }
    _isClone = false;
    final model = await _firstFile(dir, (p) => p.endsWith('.onnx'));
    final tokens = await _firstFile(dir, (p) => p.endsWith('tokens.txt'));
    if (!_phonemizerReady) {
      await piper.initBindingsAsync();
      final data = await piper.extractEspeakNgData();
      if (piper.PiperPhonemize.initialize(data) < 0) {
        throw Exception('Could not start the phonemizer');
      }
      _phonemizerReady = true;
    }
    final cfg = sherpa.OfflineTtsConfig(
      model: sherpa.OfflineTtsModelConfig(
        vits: sherpa.OfflineTtsVitsModelConfig(model: model, tokens: tokens),
        numThreads: 2,
        debug: false,
      ),
      maxNumSentences: 1,
    );
    _tts?.free();
    _tts = sherpa.OfflineTts(cfg);
    _ttsId = m.id;
    _espeak = m.espeakVoice;
  }

  bool ttsLoadedFor(VoiceModelInfo m) => _tts != null && _ttsId == m.id;

  /// Transcribes 16 kHz mono float samples.
  String transcribe(Float32List samples, {int sampleRate = 16000}) {
    final r = _stt;
    if (r == null) throw StateError('Speech recognizer not loaded');
    final s = r.createStream();
    s.acceptWaveform(samples: samples, sampleRate: sampleRate);
    r.decode(s);
    final text = r.getResult(s).text.trim();
    s.free();
    return text;
  }

  Completer<void>? _stopSignal;

  Future<void> stopSpeaking() async {
    _stopSpeaking = true;
    final sig = _stopSignal;
    if (sig != null && !sig.isCompleted) sig.complete();
    await _player.stop();
    await _system?.stop();
  }

  /// Synthesizes one chunk with the loaded on-device model.
  ({Float32List samples, int rate})? synthesize(String chunk) {
    final tts = _tts;
    if (tts == null) return null;
    if (_isClone) {
      final ref = _cloneRef;
      if (ref == null) return null;
      final audio = tts.generateWithConfig(
        text: chunk,
        config: sherpa.OfflineTtsGenerationConfig(
            sid: 0,
            speed: 1.0,
            referenceAudio: ref,
            referenceSampleRate: _cloneRate,
            numSteps: 5),
      );
      return audio.samples.isEmpty
          ? null
          : (samples: audio.samples, rate: audio.sampleRate);
    }
    final cps = piper.PiperPhonemize.phonemize(chunk, voice: _espeak)
        .where((s) => s.isNotEmpty)
        .toList();
    if (cps.isEmpty) return null;
    final audio = tts.generateWithConfig(
      text: '',
      config: sherpa.OfflineTtsGenerationConfig(
          sid: 0, speed: 1.0, phonemeCodepoints: cps),
    );
    return audio.samples.isEmpty
        ? null
        : (samples: audio.samples, rate: audio.sampleRate);
  }

  /// Asks the worker phone to speak [chunk]; returns WAV bytes or null.
  Future<Uint8List?> _remoteWav(String chunk) async {
    if (workerUrl.isEmpty) return null;
    try {
      final res = await http
          .post(Uri.parse('$workerUrl/tts'),
              headers: {
                'Authorization': 'Bearer $workerToken',
                'Content-Type': 'application/json'
              },
              body: jsonEncode({'text': chunk}))
          .timeout(const Duration(seconds: 40));
      if (res.statusCode == 200) return res.bodyBytes;
    } catch (_) {}
    return null;
  }

  /// Sends the active reference voice to the worker.
  Future<bool> uploadVoiceToWorker() async {
    final ref = _cloneRef;
    if (workerUrl.isEmpty || ref == null) return false;
    try {
      final res = await http
          .put(Uri.parse('$workerUrl/voice'),
              headers: {'Authorization': 'Bearer $workerToken'},
              body: encodeWav(ref, _cloneRate))
          .timeout(const Duration(seconds: 30));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<bool> pingWorker() async {
    if (workerUrl.isEmpty) return false;
    try {
      final res = await http
          .get(Uri.parse('$workerUrl/ping'),
              headers: {'Authorization': 'Bearer $workerToken'})
          .timeout(const Duration(seconds: 6));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<void> _playWav(Uint8List wav, int slot) async {
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/nm_tts_${slot % 2}.wav');
    await f.writeAsBytes(wav);
    final done = _player.onPlayerComplete.first;
    _stopSignal = Completer<void>();
    await _player.play(DeviceFileSource(f.path));
    await Future.any([done, _stopSignal!.future]);
  }

  /// Speaks with the worker phone, the on-device voice model, or the
  /// phone's own voice when [systemLang] is given (e.g. 'ar', 'en-US').
  Future<void> speak(String text, {String? systemLang}) async {
    _stopSpeaking = false;
    final chunks = speechChunks(text);
    if (chunks.isEmpty) return;
    final useWorker = systemLang == null && workerUrl.isNotEmpty;
    if (systemLang != null || (_tts == null && !useWorker)) {
      _system ??= FlutterTts();
      await _system!.awaitSpeakCompletion(true);
      await _system!.setLanguage(systemLang ?? 'en-US');
      for (final c in chunks) {
        if (_stopSpeaking) return;
        await _system!.speak(c);
      }
      return;
    }
    var workerOk = useWorker;
    for (var i = 0; i < chunks.length; i++) {
      if (_stopSpeaking) return;
      if (workerOk) {
        final wav = await _remoteWav(chunks[i]);
        if (wav != null) {
          await _playWav(wav, i);
          if (_stopSpeaking) return;
          continue;
        }
        workerOk = false; // fall back to this phone for the rest
      }
      final r = synthesize(chunks[i]);
      if (r == null) continue;
      await _playWav(encodeWav(r.samples, r.rate), i);
      if (_stopSpeaking) return;
    }
  }

  @override
  void onClose() {
    _stt?.free();
    _tts?.free();
    _player.dispose();
    super.onClose();
  }
}
