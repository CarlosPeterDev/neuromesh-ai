import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import '../controllers/settings_controller.dart';
import '../core/ui.dart';
import '../services/hive_service.dart';
import '../services/inference_service.dart';
import '../services/voice_models.dart';
import '../services/voice_service.dart';

const _kSttId = 'voice_stt_id';
const _kLang = 'voice_lang';
const _kSystemTts = 'voice_system_tts';

/// Download / delete voice models and choose language.
class VoiceModelsView extends StatelessWidget {
  const VoiceModelsView({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final store = Get.find<VoiceModelStore>();
    return Scaffold(
      backgroundColor: t.bg,
      appBar: appScreenBar(context, title: 'Voice models'),
      body: Obx(() {
        Widget group(VoiceKind k) => AppGroup(children: [
              for (final m in kVoiceModels.where((m) => m.kind == k))
                _row(context, store, m),
            ]);
        return ListView(padding: kPagePadding, children: [
          const Padding(
            padding: EdgeInsets.all(8),
            child: Text(
                'Voice calls run fully on your phone. Download one listening model and one speaking voice. '
                'If no speaking voice is installed, the phone\'s built-in voice is used.'),
          ),
          const SectionHeader('Listening (speech to text)'),
          group(VoiceKind.stt),
          const SectionHeader('Speaking (text to speech)'),
          group(VoiceKind.tts),
        ]);
      }),
    );
  }

  Widget _row(BuildContext c, VoiceModelStore store, VoiceModelInfo m) {
    final p = store.progress[m.id];
    final err = store.errors[m.id];
    final has = store.installed.contains(m.id);
    return AppRow(
      icon: m.kind == VoiceKind.stt ? Icons.hearing_rounded : Icons.record_voice_over_rounded,
      title: m.title,
      subtitle: err ??
          (p == null
              ? '${m.sizeLabel}${has ? ' · installed' : ''}'
              : p < 0
                  ? 'Unpacking…'
                  : 'Downloading ${(p * 100).round()}%'),
      trailing: p != null
          ? const SizedBox(
              width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
          : has
              ? IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => store.remove(m))
              : IconButton(
                  icon: const Icon(Icons.download_rounded),
                  onPressed: () => store.download(m)),
    );
  }
}

enum _CallState { starting, listening, thinking, speaking, error }

/// Hands-free voice conversation with the loaded local model.
class VoiceCallView extends StatefulWidget {
  const VoiceCallView({super.key});

  @override
  State<VoiceCallView> createState() => _VoiceCallViewState();
}

class _VoiceCallViewState extends State<VoiceCallView> {
  final _voice = Get.find<VoiceService>();
  final _store = Get.find<VoiceModelStore>();
  final _hive = Get.find<HiveService>();
  final _rec = AudioRecorder();
  final _history = <Map<String, String>>[];
  final _lines = <({bool me, String text})>[];

  _CallState _state = _CallState.starting;
  String _status = 'Getting ready…';
  String _lang = 'en';
  bool _muted = false;
  bool _ended = false;
  StreamSubscription<Uint8List>? _sub;

  // Voice activity detection
  final _speech = <double>[];
  final _preRoll = <double>[];
  bool _inSpeech = false;
  int _silentSamples = 0;
  double _noise = 0.01;
  int _calib = 0;
  bool _busy = false;

  static const _rate = 16000;

  @override
  void initState() {
    super.initState();
    _lang = _hive.getSetting<String>(_kLang) ?? 'en';
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _ended = true;
    _sub?.cancel();
    _rec.dispose();
    _voice.stopSpeaking();
    super.dispose();
  }

  void _set(_CallState s, String text) {
    if (!mounted) return;
    setState(() {
      _state = s;
      _status = text;
    });
  }

  VoiceModelInfo? _installed(VoiceKind k, {String? lang}) {
    for (final m in kVoiceModels) {
      if (m.kind != k || !_store.installed.contains(m.id)) continue;
      if (lang == null || m.lang == lang || m.lang == 'multi') return m;
    }
    return null;
  }

  Future<void> _start() async {
    if (!Get.find<InferenceService>().isModelLoaded.value) {
      _set(_CallState.error, 'Load a chat model first (Models tab).');
      return;
    }
    final stt = _installed(VoiceKind.stt);
    if (stt == null) {
      _set(_CallState.error, 'Download a listening model first (Toolbox → Voice models).');
      return;
    }
    if (!await Permission.microphone.request().isGranted) {
      _set(_CallState.error, 'Microphone permission is needed for calls.');
      return;
    }
    try {
      _set(_CallState.starting, 'Loading voice…');
      if (!_voice.sttLoadedFor(stt, _lang)) await _voice.loadStt(stt, language: _lang);
      final tts = _installed(VoiceKind.tts, lang: _lang);
      if (tts != null && !_hive.getSetting<bool>(_kSystemTts, defaultValue: false)!) {
        if (!_voice.ttsLoadedFor(tts)) await _voice.loadTts(tts);
      }
      final stream = await _rec.startStream(const RecordConfig(
          encoder: AudioEncoder.pcm16bits, sampleRate: _rate, numChannels: 1));
      _sub = stream.listen(_onAudio);
      _set(_CallState.listening, 'Listening…');
    } catch (e) {
      _set(_CallState.error, 'Could not start the call: $e');
    }
  }

  void _onAudio(Uint8List bytes) {
    if (_busy || _muted || _ended) return;
    final n = bytes.length ~/ 2;
    final bd = ByteData.sublistView(bytes);
    final chunk = Float64List(n);
    var sum = 0.0;
    for (var i = 0; i < n; i++) {
      final v = bd.getInt16(i * 2, Endian.little) / 32768.0;
      chunk[i] = v;
      sum += v * v;
    }
    final rms = math.sqrt(sum / math.max(n, 1));
    if (_calib < 8) {
      _noise = (_noise * _calib + rms) / (_calib + 1);
      _calib++;
      return;
    }
    final thr = math.max(0.02, _noise * 3);
    if (rms > thr) {
      if (!_inSpeech) {
        _inSpeech = true;
        _speech
          ..clear()
          ..addAll(_preRoll);
      }
      _silentSamples = 0;
      _speech.addAll(chunk);
    } else if (_inSpeech) {
      _speech.addAll(chunk);
      _silentSamples += n;
      final long = _speech.length > _rate * 20;
      if (_silentSamples > _rate * 0.9 || long) {
        final ok = _speech.length > _rate * 0.5;
        final samples = Float32List.fromList(_speech);
        _inSpeech = false;
        _speech.clear();
        _silentSamples = 0;
        if (ok) _turn(samples);
      }
    } else {
      _preRoll.addAll(chunk);
      final keep = (_rate * 0.3).round();
      if (_preRoll.length > keep) _preRoll.removeRange(0, _preRoll.length - keep);
    }
  }

  Future<void> _turn(Float32List samples) async {
    _busy = true;
    try {
      _set(_CallState.thinking, 'Thinking…');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final heard = _voice.transcribe(samples);
      if (heard.isEmpty) {
        _set(_CallState.listening, 'Listening…');
        return;
      }
      if (mounted) setState(() => _lines.add((me: true, text: heard)));
      final settings = Get.find<SettingsController>();
      final reply = await Get.find<InferenceService>().generate(
        prompt: heard,
        systemPrompt: '${settings.globalSystemPrompt.value}\n'
            'You are on a voice call. Answer in one to three short spoken sentences, no markdown or lists.',
        conversationHistory: List.of(_history),
        source: 'voice',
        maxTokens: 160,
      );
      if (_ended) return;
      final clean = reply.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '').trim();
      _history
        ..add({'role': 'user', 'content': heard})
        ..add({'role': 'assistant', 'content': clean});
      if (mounted) setState(() => _lines.add((me: false, text: clean)));
      _set(_CallState.speaking, 'Speaking…');
      final sys = (_installed(VoiceKind.tts, lang: _lang) == null ||
              _hive.getSetting<bool>(_kSystemTts, defaultValue: false)!)
          ? (_lang == 'ar' ? 'ar' : 'en-US')
          : null;
      await _voice.speak(clean, systemLang: sys);
    } catch (e) {
      _set(_CallState.error, 'Something went wrong: $e');
      _busy = false;
      return;
    }
    _busy = false;
    _preRoll.clear();
    _set(_CallState.listening, 'Listening…');
  }

  Future<void> _toggleLang() async {
    final next = _lang == 'en' ? 'ar' : 'en';
    await _hive.setSetting(_kLang, next);
    setState(() => _lang = next);
    final stt = _installed(VoiceKind.stt);
    if (stt != null) {
      _busy = true;
      _set(_CallState.starting, 'Switching language…');
      try {
        await _voice.loadStt(stt, language: next);
        final tts = _installed(VoiceKind.tts, lang: next);
        if (tts != null && !_voice.ttsLoadedFor(tts)) await _voice.loadTts(tts);
      } catch (_) {}
      _busy = false;
      _set(_CallState.listening, 'Listening…');
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = switch (_state) {
      _CallState.listening => Colors.green,
      _CallState.thinking => Colors.orange,
      _CallState.speaking => Colors.blue,
      _CallState.error => Colors.red,
      _ => Colors.grey,
    };
    return Scaffold(
      appBar: AppBar(title: const Text('Voice call'), actions: [
        TextButton(
            onPressed: _toggleLang,
            child: Text(_lang == 'en' ? 'English' : 'العربية')),
      ]),
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: ListView(padding: const EdgeInsets.all(16), children: [
              for (final l in _lines)
                Align(
                  alignment: l.me ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                        color: color.withValues(alpha: l.me ? 0.15 : 0.07),
                        borderRadius: BorderRadius.circular(14)),
                    child: Text(l.text),
                  ),
                ),
            ]),
          ),
          Icon(Icons.graphic_eq_rounded, size: 56, color: color),
          Padding(
              padding: const EdgeInsets.all(8),
              child: Text(_status, textAlign: TextAlign.center)),
          Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              IconButton.filledTonal(
                  iconSize: 28,
                  onPressed: () => setState(() => _muted = !_muted),
                  icon: Icon(_muted ? Icons.mic_off : Icons.mic)),
              const SizedBox(width: 24),
              IconButton.filled(
                  iconSize: 28,
                  style: IconButton.styleFrom(backgroundColor: Colors.red),
                  onPressed: () => Get.back(),
                  icon: const Icon(Icons.call_end_rounded)),
            ]),
          ),
        ]),
      ),
    );
  }
}
