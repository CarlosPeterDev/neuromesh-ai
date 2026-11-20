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

import 'device_bridge.dart';
import 'hive_service.dart';
import 'voice_models.dart';
import 'workload_placement.dart';

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
      if (size < 16 || body + 16 > b.length) return null;
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

/// Converts PCM WAV inputs to the recognizer's 16 kHz rate.
Float32List resampleWav(Float32List samples, int from, int to) {
  if (from == to || samples.isEmpty) return samples;
  if (from < 4000 || from > 384000 || to <= 0) {
    throw const FormatException('Unsupported WAV sample rate.');
  }
  final output = Float32List(math.max(1, (samples.length * to / from).round()));
  for (var i = 0; i < output.length; i++) {
    final position = i * from / to;
    final left = math.min(position.floor(), samples.length - 1);
    final right = math.min(left + 1, samples.length - 1);
    output[i] = samples[left] + (samples[right] - samples[left]) * (position - left);
  }
  return output;
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
  VoiceService({
    AudioPlayer? player,
    http.Client? workerClient,
    Future<Directory> Function()? temporaryDirectory,
    Duration playbackGrace = const Duration(seconds: 5),
  })  : _player = player ?? AudioPlayer(),
        _workerClient = workerClient,
        _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory,
        _playbackGrace = playbackGrace;

  final http.Client? _workerClient;
  final Future<Directory> Function() _temporaryDirectory;
  final Duration _playbackGrace;
  int _wavSerial = 0;
  sherpa.OfflineRecognizer? _stt;
  String? _sttId;
  sherpa.OfflineTts? _tts;
  String? _ttsId;
  String _espeak = '';
  bool _bindings = false;
  bool _phonemizerReady = false;
  Future<void> _ttsQueue = Future.value();
  Future<void> _sttQueue = Future.value();

  Future<T> _withTts<T>(Future<T> Function() action) {
    final result = _ttsQueue.then((_) => action());
    _ttsQueue = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<T> _withStt<T>(Future<T> Function() action) {
    final result = _sttQueue.then((_) => action());
    _sttQueue = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  static int savedSpeaker(VoiceModelInfo model) {
    if (model.speakers.isEmpty) return 0;
    final hive = Get.find<HiveService>();
    final saved = hive.getSetting<int>('voice_speaker_${model.id}') ??
        (hive.getSetting<String>('voice_tts_id') == model.id
            ? hive.getSetting<int>('voice_sid')
            : null) ?? 0;
    return saved.clamp(0, model.speakers.length - 1);
  }

  static Future<void> saveSpeaker(VoiceModelInfo model, int index) =>
      Get.find<HiveService>().setSetting('voice_speaker_${model.id}', index);


  final AudioPlayer _player;
  FlutterTts? _system;
  bool _stopSpeaking = false;
  bool _isClone = false;
  bool _multiSpeaker = false; // Kokoro and Kitten honor the selected speaker.
  int sid = 0;
  double speed = 1.0;
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

  Future<void> loadStt(VoiceModelInfo m, {String language = ''}) =>
      _withStt(() => _loadStt(m, language: language));

  Future<void> _loadStt(VoiceModelInfo m, {required String language}) async {
    if (sttLoadedFor(m, language)) return;
    _initBindings();
    final dir = await Get.find<VoiceModelStore>().dirFor(m);
    final tokens = await _firstFile(dir, (p) => p.endsWith('tokens.txt'));
    sherpa.OfflineModelConfig model;
    if (m.engine == 'sensevoice') {
      final f = await _firstFile(dir, (p) => p.endsWith('.onnx'));
      model = sherpa.OfflineModelConfig(
        senseVoice: sherpa.OfflineSenseVoiceModelConfig(
            model: f, language: language, useInverseTextNormalization: true),
        tokens: tokens,
        numThreads: 2,
        debug: false,
      );
    } else {
      final enc = await _firstFile(dir, (p) => p.contains('encoder') && p.endsWith('.int8.onnx'))
          .catchError((_) => _firstFile(dir, (p) => p.contains('encoder') && p.endsWith('.onnx')));
      final dec = await _firstFile(dir, (p) => p.contains('decoder') && p.endsWith('.int8.onnx'))
          .catchError((_) => _firstFile(dir, (p) => p.contains('decoder') && p.endsWith('.onnx')));
      model = sherpa.OfflineModelConfig(
        whisper: sherpa.OfflineWhisperModelConfig(
            encoder: enc, decoder: dec, language: language, task: 'transcribe'),
        tokens: tokens,
        numThreads: 2,
        debug: false,
      );
    }
    final previous = _stt;
    _stt = null;
    _sttId = null;
    previous?.free();
    _stt = await sherpa.OfflineRecognizer.createAsync(
        sherpa.OfflineRecognizerConfig(model: model));
    _sttId = '${m.id}|$language';
  }

  bool sttLoadedFor(VoiceModelInfo m, String language) =>
      _stt != null && _sttId == '${m.id}|$language';

  Future<void> loadTts(VoiceModelInfo m) => _withTts(() => _loadTts(m));

  Future<void> _loadTts(VoiceModelInfo m) async {
    if (ttsLoadedFor(m)) return;
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
      _replaceTts(m, cfg);
      return;
    }
    await _preparePhonemizer();
    if (m.engine == 'kokoro' || m.engine == 'kitten') {
      final onnx = await _firstFile(dir, (p) => p.endsWith('.onnx'));
      final voices = await _firstFile(dir, (p) => p.endsWith('voices.bin'));
      final tokens = await _firstFile(dir, (p) => p.endsWith('tokens.txt'));
      final dictDir = '$dir/dict';
      final lexicons = Directory(dir)
          .listSync()
          .whereType<File>()
          .map((f) => f.path)
          .where((p) => p.split('/').last.startsWith('lexicon') && p.endsWith('.txt'))
          .toList()
        ..sort();
      final fsts = Directory(dir)
          .listSync()
          .whereType<File>()
          .map((f) => f.path)
          .where((p) => p.endsWith('.fst'))
          .toList()
        ..sort();
      final mc = m.engine == 'kokoro'
          ? sherpa.OfflineTtsModelConfig(
              kokoro: sherpa.OfflineTtsKokoroModelConfig(
                model: onnx,
                voices: voices,
                tokens: tokens,
                dictDir: Directory(dictDir).existsSync() ? dictDir : '',
                lexicon: lexicons.join(','),
              ),
              numThreads: 4,
              debug: false)
          : sherpa.OfflineTtsModelConfig(
              kitten: sherpa.OfflineTtsKittenModelConfig(
                model: onnx,
                voices: voices,
                tokens: tokens,
              ),
              numThreads: 4,
              debug: false);
      _replaceTts(m, sherpa.OfflineTtsConfig(
          model: mc, ruleFsts: fsts.join(','), maxNumSentences: 1));
      return;
    }
    final model = await _firstFile(dir, (p) => p.endsWith('.onnx'));
    final tokens = await _firstFile(dir, (p) => p.endsWith('tokens.txt'));
    final cfg = sherpa.OfflineTtsConfig(
      model: sherpa.OfflineTtsModelConfig(
        vits: sherpa.OfflineTtsVitsModelConfig(model: model, tokens: tokens),
        numThreads: 2,
        debug: false,
      ),
      maxNumSentences: 1,
    );
    _replaceTts(m, cfg);
  }

  Future<void> _preparePhonemizer() async {
    if (_phonemizerReady) return;
    await piper.initBindingsAsync();
    final data = await piper.extractEspeakNgData();
    if (piper.PiperPhonemize.initialize(data) < 0) {
      throw StateError('Could not start the phonemizer.');
    }
    _phonemizerReady = true;
  }

  void _replaceTts(VoiceModelInfo model, sherpa.OfflineTtsConfig config) {
    final previous = _tts;
    _tts = null;
    _ttsId = null;
    previous?.free();
    _tts = sherpa.OfflineTts(config);
    _ttsId = model.id;
    _isClone = model.clone;
    _multiSpeaker = model.engine == 'kokoro' || model.engine == 'kitten';
    final modelLanguage = _tts!.lang;
    _espeak = model.espeakVoice.isNotEmpty
        ? model.espeakVoice
        : modelLanguage.isNotEmpty
            ? modelLanguage
            : 'en-us';
  }

  VoiceModelInfo? _requestedModel(VoiceKind kind, String id) {
    if (id.trim().isEmpty) return null;
    final model = voiceModelById(id.trim());
    if (model == null || model.kind != kind || model.clone ||
        !Get.find<VoiceModelStore>().installed.contains(model.id)) {
      throw ArgumentError('Choose an installed model ID from models_status.');
    }
    return model;
  }

  /// The installed model the user picked (or the first installed one).
  VoiceModelInfo? pickInstalled(VoiceKind k, {String lang = ''}) {
    final store = Get.find<VoiceModelStore>();
    final h = Get.find<HiveService>();
    final picked = h.getSetting<String>(k == VoiceKind.stt ? 'voice_stt_id' : 'voice_tts_id') ?? '';
    VoiceModelInfo? first;
    for (final m in kVoiceModels) {
      if (m.kind != k || m.clone || !store.installed.contains(m.id)) continue;
      final okLang = lang.isEmpty || m.lang == lang || m.lang == 'multi';
      if (m.id == picked && okLang) return m;
      if (okLang) first ??= m;
    }
    return first;
  }

  /// Transcribes an audio file (mp3, m4a, ogg, wav, mp4…) in 25-second pieces.
  Future<String> transcribeFile(String path, {String language = '', String modelId = ''}) async {
    final requested = _requestedModel(VoiceKind.stt, modelId);
    Float32List? pcm;
    if (path.toLowerCase().endsWith('.wav')) {
      final decoded = decodeWav(await File(path).readAsBytes());
      if (decoded != null) pcm = resampleWav(decoded.samples, decoded.rate, 16000);
    }
    pcm ??= await Get.find<DeviceBridge>().decodeAudio(path);
    if (pcm == null || pcm.isEmpty) throw Exception('Could not read audio from this file.');
    const piece = 16000 * 25;
    final out = StringBuffer();
    for (var i = 0; i < pcm.length; i += piece) {
      final end = math.min(i + piece, pcm.length);
      final t = await transcribeSamples(
          Float32List.sublistView(pcm, i, end), language: language, model: requested);
      if (t.isNotEmpty) out..write(t)..write(' ');
    }
    return out.toString().trim();
  }

  Future<String> transcribeSamples(Float32List samples,
      {String language = '', bool allowWorker = true, VoiceModelInfo? model}) async {
    final worker = allowWorker && model == null
        ? WorkloadPlacement.forWorkload(PhoneWorkload.transcription)
        : null;
    if (worker != null) {
      final bytes = await worker.request(PhoneWorkload.transcription.path,
          payload: encodeWav(samples, 16000),
          contentType: 'audio/wav',
          query: {'language': language},
          timeout: const Duration(seconds: 45),
          maxBytes: 65536);
      return utf8.decode(bytes).trim();
    }
    final selected = model ?? pickInstalled(VoiceKind.stt);
    if (selected == null) throw StateError('Install or assign a listening model.');
    return _withStt(() async {
      await _loadStt(selected, language: language);
      return transcribe(samples);
    });
  }

  /// Speaks [text] with the chosen voice into a WAV file's bytes.
  Future<Uint8List> synthesizeToWav(String text,
      {String lang = '', bool allowWorker = true, String modelId = '', String speaker = ''}) async {
    final requested = _requestedModel(VoiceKind.tts, modelId);
    final worker = allowWorker && requested == null && speaker.trim().isEmpty
        ? WorkloadPlacement.forWorkload(PhoneWorkload.speech)
        : null;
    if (worker != null) {
      return worker.request(PhoneWorkload.speech.path,
          payload: {'text': text, 'language': lang},
          timeout: const Duration(seconds: 60));
    }
    final m = requested ?? pickInstalled(VoiceKind.tts, lang: lang);
    if (m == null) {
      throw StateError('Download a speaking model in Models → Voice.');
    }
    final voice = speaker.trim().isEmpty ? savedSpeaker(m) : m.speakerIndexFor(speaker);
    if (voice == null) throw ArgumentError('Choose a speaker listed for ${m.id} in models_status.');
    final rateMultiplier = Get.find<HiveService>().getSetting<double>('voice_speed') ?? 1.0;
    return _withTts(() async {
      await _loadTts(m);
      final parts = <Float32List>[];
      var rate = 22050;
      for (final c in speechChunks(text)) {
        final r = synthesize(c, speakerIndex: voice, speakingSpeed: rateMultiplier);
        if (r == null) continue;
        parts.add(r.samples);
        rate = r.rate;
      }
      if (parts.isEmpty) throw Exception('Nothing could be spoken.');
      final all = Float32List(parts.fold<int>(0, (a, b) => a + b.length));
      var o = 0;
      for (final p in parts) {
        all.setRange(o, o + p.length, p);
        o += p.length;
      }
      return encodeWav(all, rate);
    });
  }

  bool ttsLoadedFor(VoiceModelInfo m) => _tts != null && _ttsId == m.id;

  /// Transcribes 16 kHz mono float samples.
  String transcribe(Float32List samples, {int sampleRate = 16000}) {
    final r = _stt;
    if (r == null) throw StateError('Speech recognizer not loaded');
    final stream = r.createStream();
    try {
      stream.acceptWaveform(samples: samples, sampleRate: sampleRate);
      r.decode(stream);
      return r.getResult(stream).text.trim();
    } finally {
      stream.free();
    }
  }

  Completer<void>? _stopSignal;
  Completer<void>? _speechInterruption;

  Future<void> stopSpeaking() async {
    _stopSpeaking = true;
    final interruption = _speechInterruption;
    if (interruption != null && !interruption.isCompleted) {
      interruption.complete();
    }
    final sig = _stopSignal;
    if (sig != null && !sig.isCompleted) sig.complete();
    await _stopOutput();
  }

  Future<void> _stopOutput() async {
    await Future.wait([
      _stopAudioPlayer(),
      if (_system != null)
        _system!
            .stop()
            .then<void>((_) {})
            .timeout(
              const Duration(seconds: 3),
              onTimeout: () {},
            )
            .catchError((Object _) {}),
    ]);
  }

  Future<void> _stopAudioPlayer() async {
    try {
      await _player.stop().timeout(const Duration(seconds: 3));
    } catch (_) {}
  }

  /// Synthesizes one chunk with the loaded on-device model.
  ({Float32List samples, int rate})? synthesize(String chunk,
      {int? speakerIndex, double? speakingSpeed}) {
    final voice = speakerIndex ?? sid;
    final rate = speakingSpeed ?? speed;
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
    final model = voiceModelById(_ttsId ?? '');
    if (model?.id == 'kokoro-multi' &&
        tts.config.model.kokoro.lexicon.isNotEmpty &&
        RegExp(r'\p{Script=Han}', unicode: true).hasMatch(chunk)) {
      final audio = tts.generateWithConfig(
        text: chunk,
        config: sherpa.OfflineTtsGenerationConfig(sid: voice, speed: rate),
      );
      return audio.samples.isEmpty
          ? null
          : (samples: audio.samples, rate: audio.sampleRate);
    }
    final speakerName =
        model != null && voice >= 0 && voice < model.speakers.length
            ? model.speakers[voice]
            : '';
    final locale = RegExp(r'\(([A-Z]{2}) [FM]\)$').firstMatch(speakerName)?.group(1);
    final phonemizerVoice = switch (locale) {
      'UK' => 'en-gb',
      'ES' => 'es',
      'FR' => 'fr',
      'HI' => 'hi',
      'IT' => 'it',
      'JA' => 'ja',
      'PT' => 'pt-br',
      _ => _espeak,
    };
    final cps = piper.PiperPhonemize.phonemize(chunk, voice: phonemizerVoice)
        .where((s) => s.isNotEmpty)
        .toList();
    if (cps.isEmpty) return null;
    final audio = tts.generateWithConfig(
      text: '',
      config: sherpa.OfflineTtsGenerationConfig(
          sid: _multiSpeaker ? voice : 0, speed: rate, phonemeCodepoints: cps),
    );
    return audio.samples.isEmpty
        ? null
        : (samples: audio.samples, rate: audio.sampleRate);
  }

  /// Asks the worker phone to speak [chunk]; returns WAV bytes or null.
  Future<Uint8List?> _remoteWav(String chunk, {Future<void>? cancelled}) async {
    if (workerUrl.isEmpty) return null;
    final client = _workerClient ?? http.Client();
    try {
      final request = http.Request('POST', Uri.parse('$workerUrl/tts'))
        ..followRedirects = false
        ..headers.addAll({
          'Authorization': 'Bearer $workerToken',
          'Content-Type': 'application/json',
        })
        ..body = jsonEncode({'text': chunk});
      final res = await withWorkerCancellation(
          client
              .send(request)
              .then(http.Response.fromStream)
              .timeout(const Duration(seconds: 40)),
          cancelled);
      if (res.statusCode == 200) return res.bodyBytes;
    } on WorkloadCancelled {
      rethrow;
    } catch (_) {
    } finally {
      if (_workerClient == null) client.close();
    }
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

  Future<void> _playWav(
    Uint8List wav, {
    void Function(bool)? onPlayback,
  }) async {
    final pcm = decodeWav(wav);
    if (pcm == null ||
        pcm.samples.isEmpty ||
        !pcm.samples.any((sample) => sample.abs() > 0.0001)) {
      throw const FormatException('The voice model returned silent audio.');
    }
    final duration = Duration(
      milliseconds: (pcm.samples.length * 1000 / pcm.rate).ceil(),
    );
    if (_stopSpeaking) return;
    final dir = await _temporaryDirectory();
    if (_stopSpeaking) return;
    // Android can keep a prepared audio source when the file URL repeats.
    final f = File('${dir.path}/nm_tts_${++_wavSerial}.wav');
    try {
      await f.writeAsBytes(wav);
      if (!_stopSpeaking) await _playAudioFile(f, duration, onPlayback);
    } finally {
      try {
        await f.delete();
      } on FileSystemException {
        // The cache file may already have been reclaimed.
      }
    }
  }

  Future<void> _playAudioFile(
      File file, Duration duration, void Function(bool)? onPlayback) async {
    final done = Completer<void>();
    final stopped = Completer<void>();
    _stopSignal = stopped;
    Object? playbackError;
    StackTrace? playbackStack;
    void finish() {
      if (!done.isCompleted) done.complete();
    }

    final subscription = _player.onPlayerComplete.listen(
      (_) => finish(),
      onError: (Object error, StackTrace stack) {
        playbackError = error;
        playbackStack = stack;
        finish();
      },
      onDone: finish,
    );
    try {
      await _player.play(DeviceFileSource(file.path));
      // A stop may arrive while the native player is still preparing. Its
      // late play completion must not restart audio after the interruption.
      if (_stopSpeaking) {
        await _stopAudioPlayer();
        return;
      }
      if (!done.isCompleted) onPlayback?.call(true);
      await Future.any([done.future, stopped.future])
          .timeout(duration + _playbackGrace);
      if (playbackError != null) {
        Error.throwWithStackTrace(playbackError!, playbackStack!);
      }
    } catch (_) {
      await _stopAudioPlayer();
      rethrow;
    } finally {
      onPlayback?.call(false);
      await subscription.cancel();
      if (identical(_stopSignal, stopped)) _stopSignal = null;
    }
  }

  /// Speaks with the worker phone, the on-device voice model, or the
  /// phone's own voice when [systemLang] is given (e.g. 'ar', 'en-US').
  Future<void> speak(
    String text, {
    String? systemLang,
    String workerLanguage = '',
    VoiceModelInfo? localModel,
    bool preferLocal = false,
    void Function(bool)? onPlayback,
  }) async {
    final interruption = Completer<void>();
    _speechInterruption = interruption;
    _stopSpeaking = false;
    try {
      await _speak(text,
          systemLang: systemLang,
          workerLanguage: workerLanguage,
          localModel: localModel,
          preferLocal: preferLocal,
          onPlayback: onPlayback,
          cancelled: interruption.future);
    } on WorkloadCancelled {
      // User interruption is a normal end of the utterance, not a voice error.
    } finally {
      if (identical(_speechInterruption, interruption)) {
        _speechInterruption = null;
      }
    }
  }

  Future<void> _speak(
    String text, {
    String? systemLang,
    String workerLanguage = '',
    VoiceModelInfo? localModel,
    bool preferLocal = false,
    required Future<void> cancelled,
    void Function(bool)? onPlayback,
  }) async {
    final chunks = speechChunks(text);
    if (chunks.isEmpty) return;
    final assigned = systemLang == null && !preferLocal
        ? WorkloadPlacement.forWorkload(PhoneWorkload.speech)
        : null;
    if (assigned != null) {
      for (final chunk in chunks) {
        if (_stopSpeaking) return;
        final audio = await assigned.request(PhoneWorkload.speech.path,
            payload: {'text': chunk, 'language': workerLanguage},
            cancelled: cancelled,
            timeout: const Duration(seconds: 45));
        if (_stopSpeaking) return;
        await _playWav(audio, onPlayback: onPlayback);
      }
      return;
    }
    final useWorker =
        systemLang == null && !preferLocal && workerUrl.isNotEmpty;
    final localVoice =
        localModel ?? (_ttsId == null ? null : voiceModelById(_ttsId!));
    if (systemLang != null || (localVoice == null && !useWorker)) {
      for (final c in chunks) {
        if (_stopSpeaking) return;
        await _speakSystem(c, systemLang ?? 'en-US', cancelled, onPlayback);
      }
      return;
    }
    final localSpeaker = localModel == null ? sid : savedSpeaker(localModel);
    final localSpeed = speed;
    var workerOk = useWorker;
    for (final chunk in chunks) {
      if (_stopSpeaking) return;
      if (workerOk) {
        final wav = await _remoteWav(chunk, cancelled: cancelled);
        if (_stopSpeaking) return;
        if (wav != null) {
          await _playWav(wav, onPlayback: onPlayback);
          if (_stopSpeaking) return;
          continue;
        }
        workerOk = false; // fall back to this phone for the rest
      }
      if (localVoice == null) {
        await _speakSystem(chunk, 'en-US', cancelled, onPlayback);
        continue;
      }
      final r = await _withTts(() async {
        await _loadTts(localVoice);
        return synthesize(chunk,
            speakerIndex: localSpeaker, speakingSpeed: localSpeed);
      });
      if (_stopSpeaking) return;
      if (r == null) throw StateError('The voice model returned no audio.');
      await _playWav(encodeWav(r.samples, r.rate), onPlayback: onPlayback);
      if (_stopSpeaking) return;
    }
  }

  Future<void> _speakSystem(String text, String language,
      Future<void> cancelled, void Function(bool)? onPlayback) async {
    final system = _system ??= FlutterTts();
    final preparing = () async {
      await system.awaitSpeakCompletion(true);
      await system.setLanguage(language);
    }();
    await Future.any([preparing, cancelled])
        .timeout(const Duration(seconds: 8));
    if (_stopSpeaking) return;
    try {
      onPlayback?.call(true);
      final speech = system.speak(text).then<void>((result) {
        if (result == 0 && !_stopSpeaking) {
          throw StateError('The system voice could not speak.');
        }
      });
      final seconds = 12 + text.length ~/ 7;
      await Future.any([speech, cancelled]).timeout(Duration(seconds: seconds));
    } on TimeoutException {
      await _stopOutput();
      rethrow;
    } finally {
      onPlayback?.call(false);
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
