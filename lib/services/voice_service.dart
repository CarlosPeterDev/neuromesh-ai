import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';
import 'package:piper_phonemize/piper_phonemize.dart' as piper;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

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

  Future<void> stopSpeaking() async {
    _stopSpeaking = true;
    await _player.stop();
    await _system?.stop();
  }

  /// Speaks with the on-device voice model, or the phone's own voice when
  /// [systemLang] is given instead (e.g. 'ar', 'en-US').
  Future<void> speak(String text, {String? systemLang}) async {
    _stopSpeaking = false;
    final chunks = speechChunks(text);
    if (chunks.isEmpty) return;
    if (systemLang != null || _tts == null) {
      _system ??= FlutterTts();
      await _system!.awaitSpeakCompletion(true);
      await _system!.setLanguage(systemLang ?? 'en-US');
      for (final c in chunks) {
        if (_stopSpeaking) return;
        await _system!.speak(c);
      }
      return;
    }
    final dir = await getTemporaryDirectory();
    for (var i = 0; i < chunks.length; i++) {
      if (_stopSpeaking) return;
      final cps = piper.PiperPhonemize.phonemize(chunks[i], voice: _espeak)
          .where((s) => s.isNotEmpty)
          .toList();
      if (cps.isEmpty) continue;
      final audio = _tts!.generateWithConfig(
        text: '',
        config: sherpa.OfflineTtsGenerationConfig(
            sid: 0, speed: 1.0, phonemeCodepoints: cps),
      );
      if (audio.samples.isEmpty) continue;
      final f = File('${dir.path}/nm_tts_${i % 2}.wav');
      await f.writeAsBytes(encodeWav(audio.samples, audio.sampleRate));
      final done = _player.onPlayerComplete.first;
      await _player.play(DeviceFileSource(f.path));
      await done;
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
