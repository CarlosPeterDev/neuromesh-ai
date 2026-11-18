import 'voice_views.dart';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:record/record.dart';

import '../core/ui.dart';
import '../services/hive_service.dart';
import '../services/voice_clone_store.dart';
import '../services/voice_models.dart';
import '../services/voice_service.dart';
import '../services/voice_worker.dart';

const _script =
    'The quick brown fox jumps over the lazy dog. I am recording my voice so that '
    'NeuroMesh can speak just like me. Today is a good day to build something new, '
    'and I plan to enjoy every minute of it.';

VoiceModelInfo get _cloneModel => voiceModelById('pocket-tts-clone')!;

/// Record or import a short sample of your voice, then let the app speak in it.
class VoiceCloneView extends StatefulWidget {
  final bool allowCall;
  const VoiceCloneView({super.key, this.allowCall = true});

  @override
  State<VoiceCloneView> createState() => _VoiceCloneViewState();
}

class _VoiceCloneViewState extends State<VoiceCloneView> {
  final _store = Get.find<VoiceCloneStore>();
  final _models = Get.find<VoiceModelStore>();
  final _voice = Get.find<VoiceService>();
  final _worker = Get.find<VoiceWorkerServer>();
  final _hive = Get.find<HiveService>();
  final _rec = AudioRecorder();
  final _url = TextEditingController();
  final _token = TextEditingController();

  bool _recording = false;
  int _seconds = 0;
  Timer? _timer;
  StreamSubscription<Uint8List>? _sub;
  final _pcm = <int>[];
  String _msg = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _voice.loadWorkerSettings();
    _url.text = _voice.workerUrl;
    _token.text = _voice.workerToken;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _sub?.cancel();
    _rec.dispose();
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  void _say(String m) {
    if (mounted) setState(() => _msg = m);
  }

  Future<void> _startRec() async {
    if (!await Permission.microphone.request().isGranted) {
      _say('Microphone permission is needed.');
      return;
    }
    _pcm.clear();
    final stream = await _rec.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
        noiseSuppress: true));
    _sub = stream.listen((b) => _pcm.addAll(b));
    setState(() {
      _recording = true;
      _seconds = 0;
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => _seconds++);
      if (_seconds >= 25) _stopRec();
    });
  }

  Future<void> _stopRec() async {
    _timer?.cancel();
    await _rec.stop();
    await _sub?.cancel();
    setState(() => _recording = false);
    final n = _pcm.length ~/ 2;
    if (n < 16000 * 5) {
      _say('That was too short. Record at least 5 seconds (10 to 20 is best).');
      return;
    }
    final bd = ByteData.sublistView(Uint8List.fromList(_pcm));
    final samples = Float32List(n);
    for (var i = 0; i < n; i++) {
      samples[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
    }
    if (!mounted) return;
    final name = await _askName();
    if (name == null || name.trim().isEmpty) return;
    final saved = await _store.save(name, samples, 16000);
    if (saved == null) {
      _say('Use letters and numbers in the name.');
      return;
    }
    await _store.select(saved);
    _say('Saved "$saved" and selected it.');
  }

  Future<String?> _askName() {
    final c = TextEditingController(text: 'My voice');
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Name this voice'),
        content: TextField(controller: c, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Save')),
        ],
      ),
    );
  }

  Future<void> _import() async {
    final r = await FilePicker.pickFiles(
        type: FileType.custom, allowedExtensions: const ['wav'], withData: false);
    final path = r?.files.single.path;
    if (path == null) return;
    final wav = decodeWav(await File(path).readAsBytes());
    if (wav == null) {
      _say('Only 16-bit PCM WAV files are supported.');
      return;
    }
    // Keep at most 20 seconds.
    final max = wav.rate * 20;
    final samples = wav.samples.length > max ? wav.samples.sublist(0, max) : wav.samples;
    if (samples.length < wav.rate * 3) {
      _say('The clip is too short (need at least 3 seconds).');
      return;
    }
    if (!mounted) return;
    final name = await _askName();
    if (name == null) return;
    final saved = await _store.save(name, samples, wav.rate);
    if (saved != null) {
      await _store.select(saved);
      _say('Imported "$saved".');
    }
  }

  Future<bool> _ensureEngine() async {
    if (!_models.installed.contains(_cloneModel.id)) {
      _say('Download the cloning model first.');
      return false;
    }
    if (!_voice.cloneLoaded) {
      _say('Loading the cloning model…');
      await _voice.loadTts(_cloneModel);
    }
    if (!_voice.hasCloneVoice) await _store.restoreActive();
    if (!_voice.hasCloneVoice) {
      _say('Pick or record a voice first.');
      return false;
    }
    return true;
  }

  Future<void> _preview() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (!await _ensureEngine()) return;
      _say('Speaking…');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await _voice.speak('Hello! This is how I sound with your cloned voice.');
      _say('');
    } catch (e) {
      _say('Could not speak: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleServe(bool on) async {
    if (!on) {
      await _worker.stop();
      return;
    }
    if (!await _ensureEngine()) return;
    await _worker.start();
  }

  Future<void> _saveWorker() async {
    await _hive.setSetting('voice_worker_url', _url.text.trim().replaceAll(RegExp(r'/+$'), ''));
    await _hive.setSetting('voice_worker_token', _token.text.trim());
    _voice.loadWorkerSettings();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Scaffold(
      backgroundColor: t.bg,
      appBar: appScreenBar(context, title: 'Voice cloning'),
      body: Obx(() {
        final hasModel = _models.installed.contains(_cloneModel.id);
        final p = _models.progress[_cloneModel.id];
        return ListView(padding: kPagePadding, children: [
          const Padding(
            padding: EdgeInsets.all(8),
            child: Text(
                'Record about 10-20 seconds of your voice and the app can speak in it, fully on your phone. '
                'The cloning model speaks English only. Arabic cloning is not available on-device, so Arabic uses the normal voices. '
                'Only clone your own voice or a voice you have permission to use.'),
          ),
          AppGroup(children: [
            AppRow(
              icon: Icons.download_for_offline_outlined,
              title: 'Cloning model (Pocket TTS)',
              subtitle: p == null
                  ? '${_cloneModel.sizeLabel}${hasModel ? ' · installed' : ''}'
                  : p < 0
                      ? 'Unpacking…'
                      : 'Downloading ${(p * 100).round()}%',
              trailing: hasModel
                  ? const Icon(Icons.check_circle, color: Colors.green)
                  : IconButton(
                      icon: const Icon(Icons.download_rounded),
                      onPressed: p == null ? () => _models.download(_cloneModel) : null),
            ),
          ]),
          const SectionHeader('Record your voice'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Read this aloud in a quiet room, at a normal pace:',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                const Text(_script),
                const SizedBox(height: 12),
                Row(children: [
                  FilledButton.icon(
                    onPressed: _recording ? _stopRec : _startRec,
                    icon: Icon(_recording ? Icons.stop_rounded : Icons.mic_rounded),
                    label: Text(_recording ? 'Stop ($_seconds s)' : 'Record'),
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton(onPressed: _recording ? null : _import, child: const Text('Import WAV')),
                ]),
              ]),
            ),
          ),
          if (_msg.isNotEmpty) Padding(padding: const EdgeInsets.all(8), child: Text(_msg)),
          const SectionHeader('My voices'),
          AppGroup(children: [
            if (_store.voices.isEmpty)
              const AppRow(icon: Icons.person_outline, title: 'No saved voices yet'),
            for (final v in _store.voices)
              AppRow(
                icon: _store.active.value == v ? Icons.radio_button_checked : Icons.radio_button_off,
                title: v,
                subtitle: _store.active.value == v ? 'In use' : 'Tap to use',
                onTap: () => _store.select(v),
                trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, size: 20),
                    onPressed: () => _store.remove(v)),
              ),
            AppRow(
              icon: Icons.play_circle_outline_rounded,
              title: _busy ? 'Working…' : 'Preview selected voice',
              onTap: _busy ? null : _preview,
            ),
          ]),
          const SectionHeader('Voice worker (stronger phone does the speaking)'),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
                'Cloning is heavy. On the stronger phone turn on "Serve my voice", then enter its address and key on this phone. '
                'Both phones must be on the same Wi-Fi, and the worker must keep the app open. '
                'Chat models can be shared across phones with Phone cluster; voice models cannot, so this is a separate link. '
                'If the worker is unreachable, this phone speaks by itself.',
                style: t.small),
          ),
          AppGroup(children: [
            if (widget.allowCall && _store.active.value.isNotEmpty)
              AppRow(
                icon: Icons.call_outlined,
                title: 'Call with selected voice',
                chevron: true,
                onTap: _busy ? null : () => Get.to(() => const VoiceCallView(useSelectedClone: true)),
              ),
            AppRow(
              icon: Icons.record_voice_over_rounded,
              title: 'Serve my voice to other phones',
              subtitle: _worker.running.value
                  ? '${_worker.address.value} · ${_worker.requests.value} requests'
                  : (_worker.lastError.value.isEmpty ? 'Off' : _worker.lastError.value),
              trailing: Switch(value: _worker.running.value, onChanged: _toggleServe),
            ),
            if (_worker.running.value)
              Padding(
                padding: const EdgeInsets.all(14),
                child: Column(children: [
                  Container(
                    color: Colors.white,
                    padding: const EdgeInsets.all(8),
                    child: QrImageView(
                        data: '${_worker.address.value}|${_worker.token.value}',
                        size: 160,
                        padding: EdgeInsets.zero),
                  ),
                  const SizedBox(height: 8),
                  SelectableText('Address: ${_worker.address.value}\nKey: ${_worker.token.value}'),
                ]),
              ),
          ]),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(children: [
                const Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Use a worker phone', style: TextStyle(fontWeight: FontWeight.w600))),
                TextField(
                    controller: _url,
                    decoration: const InputDecoration(hintText: 'http://192.168.1.20:8765')),
                TextField(
                    controller: _token,
                    decoration: const InputDecoration(hintText: 'Key from the worker')),
                const SizedBox(height: 8),
                Wrap(spacing: 8, children: [
                  OutlinedButton(
                      onPressed: () async {
                        await _saveWorker();
                        _say(await _voice.pingWorker()
                            ? 'Worker reachable.'
                            : 'Could not reach the worker.');
                      },
                      child: const Text('Save & test')),
                  OutlinedButton(
                      onPressed: () async {
                        await _saveWorker();
                        if (!_voice.hasCloneVoice) await _store.restoreActive();
                        _say(await _voice.uploadVoiceToWorker()
                            ? 'Voice sent to the worker.'
                            : 'Could not send the voice.');
                      },
                      child: const Text('Send my voice')),
                  TextButton(
                      onPressed: () async {
                        _url.clear();
                        _token.clear();
                        await _saveWorker();
                        _say('Worker removed. This phone speaks by itself.');
                      },
                      child: const Text('Remove')),
                ]),
              ]),
            ),
          ),
        ]);
      }),
    );
  }
}
