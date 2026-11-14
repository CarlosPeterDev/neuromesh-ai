import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../core/ui.dart';
import '../services/download_service.dart';
import '../services/inference_service.dart';

/// Measures tokens per second for the currently loaded model.
Future<String> runBenchmark() async {
  final inf = Get.find<InferenceService>();
  if (!inf.isModelLoaded.value) return 'Load a model first.';
  final sw = Stopwatch()..start();
  var first = 0;
  var tokens = 0;
  final out = await inf.generate(
    prompt: 'Write a short paragraph about the ocean.',
    systemPrompt: 'You are a helpful assistant.',
    source: 'benchmark',
    maxTokens: 64,
    onToken: (_) {
      if (tokens == 0) first = sw.elapsedMilliseconds;
      tokens++;
    },
  );
  sw.stop();
  if (out.startsWith('ERROR') || tokens == 0) return out;
  final genMs = (sw.elapsedMilliseconds - first).clamp(1, 1 << 30);
  final tps = tokens > 1 ? (tokens - 1) * 1000 / genMs : 0.0;
  return '${inf.loadedModelName.value}\n'
      'First token: ${first} ms\n'
      'Speed: ${tps.toStringAsFixed(1)} tokens/s ($tokens tokens)';
}

/// One prompt, two models, answers side by side.
class CompareView extends StatefulWidget {
  const CompareView({super.key});

  @override
  State<CompareView> createState() => _CompareViewState();
}

class _Result {
  String text = '';
  String stats = '';
}

class _CompareViewState extends State<CompareView> {
  final _prompt = TextEditingController();
  List<String> _models = [];
  String? _a;
  String? _b;
  bool _running = false;
  String _status = '';
  final _ra = _Result();
  final _rb = _Result();

  @override
  void initState() {
    super.initState();
    Get.find<DownloadService>().getDownloadedModels().then((l) {
      if (!mounted) return;
      setState(() {
        _models = l.where((n) => n.toLowerCase().endsWith('.gguf')).toList()
          ..sort();
        if (_models.length >= 2) {
          _a = _models[0];
          _b = _models[1];
        }
      });
    });
  }

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  Future<void> _runOne(String file, _Result r, String label) async {
    final dl = Get.find<DownloadService>();
    final inf = Get.find<InferenceService>();
    setState(() => _status = 'Loading $label…');
    final err = await inf.loadModel(await dl.modelPath(file), modelName: file);
    if (err.startsWith('ERROR')) {
      setState(() => r.text = err);
      return;
    }
    setState(() => _status = 'Running $label…');
    final sw = Stopwatch()..start();
    var tokens = 0;
    final out = await inf.generate(
      prompt: _prompt.text.trim(),
      systemPrompt: 'You are a helpful assistant.',
      source: 'compare',
      maxTokens: 256,
      onToken: (t) {
        tokens++;
        if (mounted) setState(() => r.text += t);
      },
    );
    sw.stop();
    setState(() {
      if (r.text.isEmpty) r.text = out;
      r.stats =
          '${(tokens * 1000 / sw.elapsedMilliseconds.clamp(1, 1 << 30)).toStringAsFixed(1)} tok/s · ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)} s';
    });
  }

  Future<void> _run() async {
    if (_a == null || _b == null || _prompt.text.trim().isEmpty || _running) {
      return;
    }
    setState(() {
      _running = true;
      _ra
        ..text = ''
        ..stats = '';
      _rb
        ..text = ''
        ..stats = '';
    });
    try {
      await _runOne(_a!, _ra, 'model A');
      await _runOne(_b!, _rb, 'model B');
    } finally {
      if (mounted) {
        setState(() {
          _running = false;
          _status = 'Done. Model B is now loaded.';
        });
      }
    }
  }

  Widget _picker(String label, String? value, ValueChanged<String?> on) =>
      DropdownButtonFormField<String>(
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(labelText: label),
        items: [
          for (final m in _models)
            DropdownMenuItem(value: m, child: Text(m, overflow: TextOverflow.ellipsis))
        ],
        onChanged: _running ? null : on,
      );

  Widget _card(String title, String? file, _Result r) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('$title · ${file ?? '-'}',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            if (r.stats.isNotEmpty) Text(r.stats, style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 6),
            SelectableText(r.text.isEmpty ? '…' : r.text),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Scaffold(
      backgroundColor: t.bg,
      appBar: appScreenBar(context, title: 'Compare models'),
      body: _models.length < 2
          ? const Center(
              child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('Download at least two GGUF models to compare them.')))
          : ListView(padding: kPagePadding, children: [
              _picker('Model A', _a, (v) => setState(() => _a = v)),
              const SizedBox(height: 8),
              _picker('Model B', _b, (v) => setState(() => _b = v)),
              const SizedBox(height: 8),
              TextField(
                  controller: _prompt,
                  minLines: 2,
                  maxLines: 5,
                  decoration: const InputDecoration(hintText: 'Prompt for both models')),
              const SizedBox(height: 8),
              FilledButton(
                  onPressed: _running ? null : _run,
                  child: Text(_running ? _status : 'Run on both')),
              if (!_running && _status.isNotEmpty)
                Padding(padding: const EdgeInsets.all(6), child: Text(_status)),
              _card('A', _a, _ra),
              _card('B', _b, _rb),
            ]),
    );
  }
}
