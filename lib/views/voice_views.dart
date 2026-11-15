import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../controllers/settings_controller.dart';
import '../core/ui.dart';
import '../services/hive_service.dart';
import '../services/inference_service.dart';
import '../services/voice_clone_store.dart';
import '../services/voice_models.dart';
import '../services/voice_service.dart';

const _kSttId = 'voice_stt_id';
const _kLang = 'voice_lang';
const _kSystemTts = 'voice_system_tts';
const _kBargeIn = 'voice_barge_in';
const _kWakePhrase = 'voice_wake_phrase';

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
          const SectionHeader('Better turn-taking (recommended)'),
          group(VoiceKind.vad),
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
  bool _bargeIn = false;
  String _wake = '';
  StreamSubscription<Uint8List>? _sub;

  // Smart detector (Silero) when installed; otherwise a simple energy gate.
  sherpa.VoiceActivityDetector? _vad;
  final _vadBuf = <double>[];

  final _speech = <double>[];
  final _preRoll = <double>[];
  bool _inSpeech = false;
  int _silentSamples = 0;
  double _noise = 0.01;
  int _calib = 0;

  bool _busy = false; // transcribing / thinking
  bool _speaking = false;
  int _bargeFrames = 0;
  final _pending = <Float32List>[]; // utterances that arrive while busy
  bool _interrupted = false;

  static const _rate = 16000;

  @override
  void initState() {
    super.initState();
    _lang = _hive.getSetting<String>(_kLang) ?? 'en';
    _bargeIn = _hive.getSetting<bool>(_kBargeIn, defaultValue: false) ?? false;
    _wake = (_hive.getSetting<String>(_kWakePhrase) ?? '').trim().toLowerCase();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _ended = true;
    _sub?.cancel();
    _rec.dispose();
    _vad?.free();
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
      if (m.clone) continue; // chosen separately by _ttsChoice
      if (lang == null || m.lang == lang || m.lang == 'multi') return m;
    }
    return null;
  }

  /// The cloning voice when you picked one (English only), else a normal voice.
  VoiceModelInfo? _ttsChoice(String lang) {
    final clones = Get.find<VoiceCloneStore>();
    if (lang == 'en' && clones.active.value.isNotEmpty) {
      final m = voiceModelById('pocket-tts-clone');
      if (m != null && _store.installed.contains(m.id)) return m;
    }
    return _installed(VoiceKind.tts, lang: lang);
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
      final tts = _ttsChoice(_lang);
      if (tts != null && !_hive.getSetting<bool>(_kSystemTts, defaultValue: false)!) {
        if (!_voice.ttsLoadedFor(tts)) await _voice.loadTts(tts);
        if (tts.clone && !_voice.hasCloneVoice) {
          await Get.find<VoiceCloneStore>().restoreActive();
        }
      }
      _voice.loadWorkerSettings();
      _vad = await _voice.createVad();
      final stream = await _rec.startStream(const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: _rate,
          numChannels: 1,
          echoCancel: true,
          noiseSuppress: true));
      _sub = stream.listen(_onAudio);
      _set(_CallState.listening, _listeningText());
    } catch (e) {
      _set(_CallState.error, 'Could not start the call: $e');
    }
  }

  String _listeningText() => _wake.isEmpty ? 'Listening…' : 'Say "$_wake" to talk';

  Float64List _toFloat(Uint8List bytes) {
    final n = bytes.length ~/ 2;
    final bd = ByteData.sublistView(bytes);
    final out = Float64List(n);
    for (var i = 0; i < n; i++) {
      out[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
    }
    return out;
  }

  void _onAudio(Uint8List bytes) {
    if (_ended || _muted) return;
    final chunk = _toFloat(bytes);

    // While the model is speaking, only look for the user interrupting.
    if (_speaking) {
      if (!_bargeIn) return;
      _bargeCheck(chunk);
      return;
    }
    if (_busy) return;
    if (_vad != null) {
      _onAudioVad(chunk);
    } else {
      _onAudioEnergy(chunk);
    }
  }

  void _bargeCheck(Float64List chunk) {
    var sum = 0.0;
    for (final v in chunk) {
      sum += v * v;
    }
    final rms = math.sqrt(sum / math.max(chunk.length, 1));
    // Needs clearly louder than background, for ~0.4 s in a row.
    if (rms > math.max(0.06, _noise * 6)) {
      _bargeFrames += chunk.length;
      if (_bargeFrames > _rate * 0.4) {
        _bargeFrames = 0;
        _interrupted = true;
        _voice.stopSpeaking();
      }
    } else {
      _bargeFrames = 0;
    }
  }

  void _onAudioVad(Float64List chunk) {
    _vadBuf.addAll(chunk);
    while (_vadBuf.length >= 512) {
      final win = Float32List.fromList(_vadBuf.sublist(0, 512));
      _vadBuf.removeRange(0, 512);
      _vad!.acceptWaveform(win);
    }
    while (!_vad!.isEmpty()) {
      final seg = _vad!.front();
      _vad!.pop();
      if (seg.samples.length > _rate * 0.4) _turn(seg.samples);
    }
  }

  void _onAudioEnergy(Float64List chunk) {
    final n = chunk.length;
    var sum = 0.0;
    for (final v in chunk) {
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

  /// Speaks sentences as the model writes them, one after another.
  Future<void> _speakQueue(Stream<String> sentences, String? sysLang) async {
    await for (final s in sentences) {
      if (_ended || _interrupted) break;
      await _voice.speak(s, systemLang: sysLang);
    }
  }

  Future<void> _turn(Float32List samples) async {
    if (_busy) {
      if (_pending.length < 2) _pending.add(samples);
      return;
    }
    _busy = true;
    try {
      _set(_CallState.thinking, 'Thinking…');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      var heard = _voice.transcribe(samples);
      if (heard.isNotEmpty && _wake.isNotEmpty) {
        final low = heard.toLowerCase();
        final at = low.indexOf(_wake);
        if (at < 0) {
          _set(_CallState.listening, _listeningText());
          return;
        }
        heard = heard.substring(at + _wake.length).replaceFirst(RegExp(r'^[\s,.!?]+'), '');
      }
      if (heard.isEmpty) {
        _set(_CallState.listening, _listeningText());
        return;
      }
      if (mounted) setState(() => _lines.add((me: true, text: heard)));

      final settings = Get.find<SettingsController>();
      final workerForEnglish = _voice.workerUrl.isNotEmpty && _lang == 'en';
      final sys = ((_ttsChoice(_lang) == null && !workerForEnglish) ||
              _hive.getSetting<bool>(_kSystemTts, defaultValue: false)!)
          ? (_lang == 'ar' ? 'ar' : 'en-US')
          : null;

      _interrupted = false;
      final ctl = StreamController<String>();
      var raw = '';
      var read = 0;
      var started = false;
      final speakingDone = _speakQueue(ctl.stream, sys);

      final reply = await Get.find<InferenceService>().generate(
        prompt: heard,
        systemPrompt: '${settings.globalSystemPrompt.value}\n'
            'You are on a voice call. Answer in one to three short spoken sentences, no markdown or lists.',
        conversationHistory: List.of(_history),
        source: 'voice',
        maxTokens: 160,
        onToken: (t) {
          raw += t;
          final r = nextSentences(raw, read);
          read = r.next;
          for (final sentence in r.sentences) {
            if (!started) {
              started = true;
              _speaking = true;
              _set(_CallState.speaking, 'Speaking…');
            }
            ctl.add(sentence);
          }
        },
      );
      final finalRaw = raw.isEmpty ? reply : raw;
      final tail = nextSentences(finalRaw, read, flush: true);
      for (final sentence in tail.sentences) {
        if (!started) {
          started = true;
          _speaking = true;
          _set(_CallState.speaking, 'Speaking…');
        }
        ctl.add(sentence);
      }
      await ctl.close();

      final clean = finalRaw.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '').trim();
      _history
        ..add({'role': 'user', 'content': heard})
        ..add({'role': 'assistant', 'content': clean});
      if (mounted) setState(() => _lines.add((me: false, text: clean)));
      await speakingDone;
    } catch (e) {
      _speaking = false;
      _busy = false;
      _set(_CallState.error, 'Something went wrong: $e');
      return;
    }
    _speaking = false;
    _busy = false;
    _preRoll.clear();
    _vadBuf.clear();
    _vad?.reset();
    _set(_CallState.listening, _listeningText());
    if (_pending.isNotEmpty && !_ended) {
      final next = _pending.removeAt(0);
      unawaited(_turn(next));
    }
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
        final tts = _ttsChoice(next);
        if (tts != null && !_voice.ttsLoadedFor(tts)) await _voice.loadTts(tts);
      } catch (_) {}
      _busy = false;
      _set(_CallState.listening, _listeningText());
    }
  }

  Future<void> _editWake() async {
    final ctl = TextEditingController(text: _wake);
    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Wake phrase'),
        content: TextField(
            controller: ctl,
            autofocus: true,
            decoration: const InputDecoration(
                hintText: 'e.g. hey neuro. Empty = answer everything')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, ctl.text), child: const Text('Save')),
        ],
      ),
    );
    if (r == null) return;
    await _hive.setSetting(_kWakePhrase, r.trim());
    setState(() => _wake = r.trim().toLowerCase());
    if (_state == _CallState.listening) _set(_CallState.listening, _listeningText());
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
        IconButton(
            tooltip: 'Wake phrase',
            icon: Icon(_wake.isEmpty ? Icons.hearing_disabled_outlined : Icons.hearing),
            onPressed: _editWake),
        IconButton(
            tooltip: _bargeIn ? 'Interrupting: on (use headphones)' : 'Interrupting: off',
            icon: Icon(_bargeIn ? Icons.front_hand : Icons.front_hand_outlined),
            onPressed: () async {
              setState(() => _bargeIn = !_bargeIn);
              await _hive.setSetting(_kBargeIn, _bargeIn);
            }),
        TextButton(
            onPressed: _toggleLang,
            child: Text(_lang == 'en' ? 'English' : 'العربية')),
      ]),
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: ListView(padding: const EdgeInsets.all(16), children: [
              if (_vad == null && _state == _CallState.listening)
                const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text(
                        'Tip: install the smart speech detector (Toolbox → Voice models) for better turn-taking.',
                        style: TextStyle(fontSize: 12))),
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
