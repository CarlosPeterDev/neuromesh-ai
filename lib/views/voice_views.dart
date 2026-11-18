import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../controllers/settings_controller.dart';
import '../core/ui.dart';
import '../services/agent_service.dart';
import '../services/hive_service.dart';
import '../services/model_transfer_service.dart';
import 'model_transfer_view.dart';
import '../widgets/agent_steps.dart';
import '../widgets/tool_confirm.dart';
import '../services/inference_service.dart';
import '../services/voice_clone_store.dart';
import '../services/voice_models.dart';
import '../services/voice_service.dart';
import '../services/workload_placement.dart';

const _kLang = 'voice_lang';
const _kSystemTts = 'voice_system_tts';
const _kBargeIn = 'voice_barge_in';
const _kWakePhrase = 'voice_wake_phrase';
const _kSttId = 'voice_stt_id';
const _kTtsId = 'voice_tts_id';
const _kSid = 'voice_sid';
const _kSpeed = 'voice_speed';

class VoiceModelsView extends StatelessWidget {
  const VoiceModelsView({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: AppTokens.of(context).bg,
        appBar: appScreenBar(context, title: 'Voice models'),
        body: ListView(
          padding: kPagePadding,
          children: const [VoiceModelCatalog()],
        ),
      );
}

/// Downloads, model selection, and voice options shared by both entry points.
class VoiceModelCatalog extends StatefulWidget {
  const VoiceModelCatalog({super.key});

  @override
  State<VoiceModelCatalog> createState() => _VoiceModelCatalogState();
}

class _VoiceModelCatalogState extends State<VoiceModelCatalog> {
  final _hive = Get.find<HiveService>();
  final _store = Get.find<VoiceModelStore>();
  bool _previewing = false;
  String? _exportingModel;

  String get _sttId => _hive.getSetting<String>(_kSttId) ?? '';
  String get _ttsId => _hive.getSetting<String>(_kTtsId) ?? '';
  int get _sid => _hive.getSetting<int>(_kSid) ?? 0;
  double get _speed => _hive.getSetting<double>(_kSpeed) ?? 1.0;

  /// The model that will actually be used for [kind]: the picked one if it is
  /// installed, otherwise the first installed one.
  VoiceModelInfo? _effective(VoiceKind kind, String picked) {
    final list = kVoiceModels
        .where((m) => m.kind == kind && !m.clone && _store.installed.contains(m.id))
        .toList();
    for (final m in list) {
      if (m.id == picked) return m;
    }
    return list.isEmpty ? null : list.first;
  }

  Future<void> _preview(VoiceModelInfo m) async {
    setState(() => _previewing = true);
    try {
      final v = Get.find<VoiceService>();
      v.sid = _sid;
      v.speed = _speed;
      if (!v.ttsLoadedFor(m)) await v.loadTts(m);
      await v.speak(m.lang == 'ar'
          ? 'مرحباً، هذا صوتي. كيف يبدو؟'
          : 'Hello, this is how I sound. Do you like this voice?');
    } catch (e) {
      Get.snackbar('Could not play the voice', '$e');
    } finally {
      if (mounted) setState(() => _previewing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      _store.installed.length; // rebuild when downloads finish / are removed
      _store.progress.length;
      Widget group(VoiceKind k) => AppGroup(children: [
            for (final m in kVoiceModels.where((m) => m.kind == k))
              _row(context, m),
          ]);
      final tts = _effective(VoiceKind.tts, _ttsId);
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Padding(
          padding: EdgeInsets.all(8),
          child: Text(
              'Download a listening or speaking model, then tap it to select it.'),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.file_open_rounded),
              label: const Text('Import voice model (.zip)'),
              onPressed: () async {
                final r = await FilePicker.pickFiles(
                    type: FileType.custom, allowedExtensions: ['zip']);
                final path = r?.files.single.path;
                if (path == null) return;
                try {
                  final m = await _store.importZip(path);
                  await _store.scan();
                  Get.snackbar('Imported', m.title);
                  if (mounted) setState(() {});
                } catch (e) {
                  Get.snackbar('Import failed', '$e');
                }
              },
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.swap_horiz_rounded),
              label: const Text('Send / receive on Wi-Fi'),
              onPressed: () => Get.to(() => const ModelTransferView()),
            ),
          ]),
        ),
        const SectionHeader('Listening (speech to text)'),
        group(VoiceKind.stt),
        const SectionHeader('Speaking (text to speech)'),
        group(VoiceKind.tts),
        if (tts != null) ...[
          const SectionHeader('Voice options'),
          _voiceOptions(tts),
        ],
        const SectionHeader('Better turn-taking (recommended)'),
        group(VoiceKind.vad),
      ]);
    });
  }

  Widget _voiceOptions(VoiceModelInfo tts) {
    final sp = tts.speakers;
    final sid = sp.isEmpty ? 0 : _sid.clamp(0, sp.length - 1);
    return AppGroup(children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Using: ${tts.title}', style: const TextStyle(fontWeight: FontWeight.w600)),
          if (sp.isNotEmpty) ...[
            const SizedBox(height: 8),
            DropdownButton<int>(
              isExpanded: true,
              value: sid,
              items: [
                for (var i = 0; i < sp.length; i++)
                  DropdownMenuItem(value: i, child: Text(sp[i])),
              ],
              onChanged: (v) {
                _hive.setSetting(_kSid, v ?? 0);
                setState(() {});
              },
            ),
          ] else
            const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text('This model has a single voice.')),
          Row(children: [
            const Text('Speed'),
            Expanded(
              child: Slider(
                min: 0.6,
                max: 1.6,
                divisions: 10,
                label: '${_speed.toStringAsFixed(1)}x',
                value: _speed.clamp(0.6, 1.6),
                onChanged: (v) {
                  _hive.setSetting(_kSpeed, v);
                  setState(() {});
                },
              ),
            ),
          ]),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: _previewing ? null : () => _preview(tts),
              icon: _previewing
                  ? const SizedBox(
                      width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.play_arrow_rounded),
              label: const Text('Try this voice'),
            ),
          ),
        ]),
      ),
    ]);
  }

  Widget _row(BuildContext c, VoiceModelInfo m) {
    final store = _store;
    final p = store.progress[m.id];
    final err = store.errors[m.id];
    final has = store.installed.contains(m.id);
    final picked = !m.clone &&
        has &&
        (m.kind == VoiceKind.stt
            ? _effective(VoiceKind.stt, _sttId)?.id == m.id
            : m.kind == VoiceKind.tts
                ? _effective(VoiceKind.tts, _ttsId)?.id == m.id
                : false);
    return AppRow(
      icon: m.kind == VoiceKind.stt ? Icons.hearing_rounded : Icons.record_voice_over_rounded,
      title: m.title,
      subtitle: err ??
          (p == null
              ? '${m.sizeLabel}${has ? ' · installed' : ''}${picked ? ' · in use' : ''}'
              : p < 0
                  ? 'Unpacking…'
                  : 'Downloading ${(p * 100).round()}%'),
      onTap: has && !m.clone && m.kind != VoiceKind.vad
          ? () {
              _hive.setSetting(m.kind == VoiceKind.stt ? _kSttId : _kTtsId, m.id);
              _hive.setSetting(_kSid, 0);
              setState(() {});
            }
          : null,
      trailing: p != null
          ? Row(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, value: p > 0 ? p : null)),
              if (p >= 0)
                IconButton(
                    tooltip: 'Cancel download',
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => store.cancel(m.id)),
            ])
          : has
              ? Row(mainAxisSize: MainAxisSize.min, children: [
                  if (picked) const Icon(Icons.check_circle_rounded, size: 20),
                  if (!m.clone && m.kind != VoiceKind.vad)
                    IconButton(
                        tooltip: 'Export as .zip (save or send)',
                        icon: _exportingModel == m.id
                            ? const SizedBox(width: 18, height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.ios_share_rounded),
                        onPressed: _exportingModel != null ? null : () async {
                          setState(() => _exportingModel = m.id);
                          try {
                            final msg = await store.exportZip(m);
                            if (mounted) Get.snackbar('Export', msg);
                          } catch (e) {
                            if (mounted) Get.snackbar('Export failed', '$e');
                          } finally {
                            if (mounted) setState(() => _exportingModel = null);
                          }
                        }),
                  IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: _exportingModel == m.id ? null : () {
                        store.remove(m);
                        setState(() {});
                      }),
                ])
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
  CameraController? _cam;
  bool _camBusy = false;

  /// Video call: the camera opens and the model sees a frame with every
  /// sentence you say. Needs a vision model.
  Future<void> _toggleCamera() async {
    if (_cam != null) {
      final c = _cam;
      setState(() => _cam = null);
      await c?.dispose();
      return;
    }
    if (!Get.find<InferenceService>().isVisionLoaded.value) {
      Get.snackbar('Video call needs a vision model',
          'Load a model that can see images (Models → filter: Vision), then try again.');
      return;
    }
    if (_camBusy) return;
    _camBusy = true;
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) throw Exception('No camera found.');
      final cam = cams.firstWhere((c) => c.lensDirection == CameraLensDirection.front,
          orElse: () => cams.first);
      final ctl = CameraController(cam, ResolutionPreset.low, enableAudio: false);
      await ctl.initialize();
      if (!mounted) {
        await ctl.dispose();
        return;
      }
      setState(() => _cam = ctl);
    } catch (e) {
      Get.snackbar('Camera unavailable', '$e');
    } finally {
      _camBusy = false;
    }
  }

  Future<String?> _snap() async {
    final c = _cam;
    if (c == null || !c.value.isInitialized) return null;
    try {
      return (await c.takePicture()).path;
    } catch (_) {
      return null;
    }
  }
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
    _micWatchdog?.cancel();
    _cam?.dispose();
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
    final picked = _hive.getSetting<String>(k == VoiceKind.stt ? _kSttId : _kTtsId) ?? '';
    if (picked.isNotEmpty && (k == VoiceKind.stt || k == VoiceKind.tts)) {
      final m = voiceModelById(picked);
      if (m != null &&
          m.kind == k &&
          !m.clone &&
          _store.installed.contains(m.id) &&
          (lang == null || m.lang == lang || m.lang == 'multi')) {
        return m;
      }
    }
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
    _voice.sid = _hive.getSetting<int>(_kSid) ?? 0;
    _voice.speed = _hive.getSetting<double>(_kSpeed) ?? 1.0;
    final stt = _installed(VoiceKind.stt);
    final remoteStt = WorkloadPlacement.forWorkload(PhoneWorkload.transcription);
    if (stt == null && remoteStt == null) {
      _set(_CallState.error, 'Download a listening model or assign a phone worker.');
      return;
    }
    if (!await Permission.microphone.request().isGranted) {
      _set(_CallState.error, 'Microphone permission is needed for calls.');
      return;
    }
    try {
      _set(_CallState.starting, 'Loading voice…');
      if (remoteStt == null && stt != null && !_voice.sttLoadedFor(stt, _lang)) {
        await _voice.loadStt(stt, language: _lang);
      }
      final tts = _ttsChoice(_lang);
      if (tts != null &&
          WorkloadPlacement.forWorkload(PhoneWorkload.speech) == null &&
          !_hive.getSetting<bool>(_kSystemTts, defaultValue: false)!) {
        if (!_voice.ttsLoadedFor(tts)) await _voice.loadTts(tts);
        if (tts.clone && !_voice.hasCloneVoice) {
          await Get.find<VoiceCloneStore>().restoreActive();
        }
      }
      _voice.loadWorkerSettings();
      _vad = await _voice.createVad();
      final stream = await _rec.startStream(_recConfig);
      _lastAudio = DateTime.now();
      _sub = stream.listen(_onAudio);
      _startMicWatchdog();
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
    _lastAudio = DateTime.now();
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
  Future<void> _speakQueue(Stream<String> sentences, String? sysLang,
      {void Function(String sentence)? onSpoken}) async {
    await for (final s in sentences) {
      if (_ended || _interrupted) break;
      onSpoken?.call(s); // the caption grows as each sentence is spoken
      await _voice.speak(s, systemLang: sysLang, workerLanguage: _lang);
    }
  }

  /// What is worth reading aloud: no markdown, links, tool traces or thinking.
  static String _spoken(String t) => t
      .replaceAll(RegExp(r'<think>[\s\S]*?(</think>|$)'), '')
      .split('\n')
      .where((l) => !l.startsWith('>'))
      .join('\n')
      .replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), '')
      .replaceAllMapped(RegExp(r'\[([^\]]*)\]\([^)]*\)'), (m) => m.group(1) ?? '')
      .replaceAll(RegExp(r'[*_`#]+'), '')
      .trim();

  final _shots = <File>[];

  Future<void> _turn(Float32List samples) async {
    if (_busy) {
      if (_pending.length < 2) _pending.add(samples);
      return;
    }
    _busy = true;
    try {
      _set(_CallState.thinking, 'Thinking…');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      var heard = await _voice.transcribeSamples(samples, language: _lang);
      if (heard.isNotEmpty && _wake.isNotEmpty) {
        final low = heard.toLowerCase();
        final at = low.indexOf(_wake);
        if (at < 0) {
          _afterTurn();
          return;
        }
        heard = heard.substring(at + _wake.length).replaceFirst(RegExp(r'^[\s,.!?]+'), '');
      }
      if (heard.isEmpty) {
        _afterTurn();
        return;
      }
      if (mounted) setState(() => _lines.add((me: true, text: heard)));

      final settings = Get.find<SettingsController>();
      final canSpeakRemotely =
          WorkloadPlacement.forWorkload(PhoneWorkload.speech) != null ||
          (_voice.workerUrl.isNotEmpty && _lang == 'en');
      final sys = ((_ttsChoice(_lang) == null && !canSpeakRemotely) ||
              _hive.getSetting<bool>(_kSystemTts, defaultValue: false)!)
          ? (_lang == 'ar' ? 'ar' : 'en-US')
          : null;

      _interrupted = false;
      final ctl = StreamController<String>();
      var read = 0;
      var started = false;
      int? liveIdx;
      void caption(String sentence) {
        if (!mounted) return;
        setState(() {
          if (liveIdx == null) {
            _lines.add((me: false, text: sentence));
            liveIdx = _lines.length - 1;
          } else {
            _lines[liveIdx!] = (me: false, text: '${_lines[liveIdx!].text} $sentence');
          }
        });
      }

      final speakingDone = _speakQueue(ctl.stream, sys, onSpoken: caption);

      void feed(String text, {bool flush = false}) {
        final v = _spoken(text);
        if (v.length < read) read = 0; // a new segment after a tool step
        final r = nextSentences(v, read, flush: flush);
        read = r.next;
        for (final sentence in r.sentences) {
          if (!started) {
            started = true;
            _speaking = true;
            _set(_CallState.speaking, 'Speaking…');
          }
          ctl.add(sentence);
        }
      }

      final shot = await _snap();
      final agent = Get.find<AgentService>();
      final inference = Get.find<InferenceService>();
      final settings2 = settings;
      final useTools = agent.wantsTools(heard);
      final system = agent.composeSystem(
          '${settings2.globalSystemPrompt.value}\n'
          'You are on a voice call. Speak naturally in one to three short sentences. No markdown, lists or emoji. '
          'If you used tools, just say the result.',
          withTools: useTools);
      Future<String> gen(String prompt, List<Map<String, String>> hist, void Function(String) onTok) =>
          inference.generate(
            prompt: prompt,
            systemPrompt: system,
            conversationHistory: hist,
            source: 'voice',
            imagePath: shot,
            maxTokens: useTools ? 500 : 160,
            onToken: onTok,
          );

      String finalText;
      if (!useTools) {
        var raw = '';
        final reply = await gen(heard, List.of(_history), (t) {
          raw += t;
          feed(raw);
        });
        finalText = raw.isEmpty ? reply : raw;
        feed(finalText, flush: true);
      } else {
        final result = await agent.runToolLoop(
          generate: gen,
          prompt: heard,
          history: List.of(_history),
          confirm: confirmToolCall,
          userText: heard,
          researchQuestion: agent.needsResearch(heard) ? heard : null,
          cancelled: () => _ended || _interrupted,
          onVisible: (v) => feed(v),
          onStatus: (st) {
            if (!_speaking) _set(_CallState.thinking, st);
          },
        );
        finalText = result.markdown;
        feed(_spoken(finalText), flush: true);
        for (final m in RegExp(r'!\[[^\]]*\]\(nmfile:([^)]+)\)').allMatches(finalText)) {
          final f = await agentFile(m.group(1)!);
          if (f != null && mounted) setState(() => _shots.add(f));
        }
      }
      await ctl.close();

      final clean = _spoken(finalText);
      _history
        ..add({'role': 'user', 'content': heard})
        ..add({'role': 'assistant', 'content': clean});
      if (liveIdx == null && clean.isNotEmpty && mounted) {
        setState(() => _lines.add((me: false, text: clean)));
      }
      // Never wait forever for the voice to finish: a lost completion callback
      // used to leave the call deaf to every later question.
      await speakingDone.timeout(const Duration(seconds: 180), onTimeout: () {
        _voice.stopSpeaking();
      });
    } catch (e) {
      // Show the problem but keep the call alive so the next question works.
      if (mounted) setState(() => _lines.add((me: false, text: '⚠️ $e')));
    }
    _afterTurn();
    if (_pending.isNotEmpty && !_ended) {
      final next = _pending.removeAt(0);
      unawaited(_turn(next));
    }
  }

  /// Gets the call ready to hear the next question: clears every buffer and
  /// detector state left over from the last one.
  void _afterTurn() {
    _speaking = false;
    _busy = false;
    _interrupted = false;
    _inSpeech = false;
    _silentSamples = 0;
    _bargeFrames = 0;
    _speech.clear();
    _preRoll.clear();
    _vadBuf.clear();
    try {
      _vad?.reset();
    } catch (_) {}
    _set(_CallState.listening, _listeningText());
  }

  static const _recConfig = RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: _rate,
      numChannels: 1,
      echoCancel: true,
      noiseSuppress: true);
  DateTime _lastAudio = DateTime.now();
  Timer? _micWatchdog;

  /// Android can silently stop the microphone when the voice starts playing.
  /// If no audio arrives for a few seconds, open the microphone again.
  void _startMicWatchdog() {
    _micWatchdog?.cancel();
    _micWatchdog = Timer.periodic(const Duration(seconds: 3), (_) async {
      if (_ended || _muted) return;
      if (DateTime.now().difference(_lastAudio) < const Duration(seconds: 4)) return;
      try {
        await _sub?.cancel();
        await _rec.stop();
        final stream = await _rec.startStream(_recConfig);
        _lastAudio = DateTime.now();
        _sub = stream.listen(_onAudio);
      } catch (_) {}
    });
  }

  Future<void> _toggleLang() async {
    final next = _lang == 'en' ? 'ar' : 'en';
    await _hive.setSetting(_kLang, next);
    setState(() => _lang = next);
    final stt = _installed(VoiceKind.stt);
    if (stt != null && WorkloadPlacement.forWorkload(PhoneWorkload.transcription) == null) {
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
          if (_cam != null && _cam!.value.isInitialized)
            SizedBox(height: 150, child: ClipRRect(
                borderRadius: BorderRadius.circular(12), child: CameraPreview(_cam!))),
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
              if (_shots.isNotEmpty)
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final f in _shots)
                    GestureDetector(
                      onTap: () => showDialog(
                          context: context,
                          builder: (_) => Dialog(child: InteractiveViewer(child: Image.file(f)))),
                      child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.file(f, height: 160, fit: BoxFit.cover)),
                    ),
                ]),
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
              const SizedBox(width: 16),
              IconButton.filledTonal(
                  iconSize: 28,
                  tooltip: 'Video call (vision models)',
                  onPressed: _toggleCamera,
                  icon: Icon(_cam != null ? Icons.videocam : Icons.videocam_off_outlined)),
              const SizedBox(width: 16),
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
