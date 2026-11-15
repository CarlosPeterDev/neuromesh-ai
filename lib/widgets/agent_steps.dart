import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:share_plus/share_plus.dart';

import '../services/agent_service.dart';

/// One tool step the agent took, parsed from a saved trace line.
class AgentStep {
  final String name;
  final String label;
  final Map<String, dynamic> args;
  final String result;
  final bool running;
  final int ms;
  const AgentStep(this.name, this.label, this.args, this.result, this.running, this.ms);

  static AgentStep? parse(String line) {
    if (!line.startsWith(ToolLoopResult.traceMark)) return null;
    try {
      final j = jsonDecode(line.substring(ToolLoopResult.traceMark.length));
      if (j is! Map) return null;
      return AgentStep(
        '${j['n'] ?? ''}',
        '${j['l'] ?? j['n'] ?? ''}',
        (j['a'] is Map) ? Map<String, dynamic>.from(j['a'] as Map) : <String, dynamic>{},
        '${j['r'] ?? ''}',
        j['run'] == true,
        (j['ms'] is num) ? (j['ms'] as num).toInt() : 0,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Splits a message into its structured steps and the rest of the text.
/// Old-style trace lines (plain markdown) stay in the text.
(List<AgentStep>, String) splitSteps(String content) {
  if (!content.contains(ToolLoopResult.traceMark)) return (const [], content);
  final steps = <AgentStep>[];
  final rest = <String>[];
  for (final l in content.split('\n')) {
    final s = AgentStep.parse(l);
    if (s != null) {
      steps.add(s);
    } else {
      rest.add(l);
    }
  }
  return (steps, rest.join('\n').trimLeft());
}

IconData _iconFor(String n) {
  switch (n) {
    case 'web_search':
      return Icons.travel_explore_rounded;
    case 'fetch_url':
      return Icons.public_rounded;
    case 'run_shell':
      return Icons.terminal_rounded;
    case 'read_file':
    case 'read_user_file':
    case 'search_in_file':
    case 'list_files':
    case 'list_folder':
    case 'file_info':
      return Icons.description_outlined;
    case 'write_file':
    case 'write_user_file':
      return Icons.edit_note_rounded;
    case 'transcribe_audio':
      return Icons.hearing_rounded;
    case 'text_to_speech':
      return Icons.record_voice_over_rounded;
    case 'generate_image':
      return Icons.image_outlined;
    case 'device_status':
      return Icons.battery_charging_full_rounded;
    case 'remember':
    case 'forget':
      return Icons.psychology_alt_outlined;
    case 'ask_user':
      return Icons.help_outline_rounded;
    default:
      return Icons.build_circle_outlined;
  }
}

/// A collapsible "what the agent did" list; tap a step for its details.
class AgentStepsView extends StatelessWidget {
  final List<AgentStep> steps;
  const AgentStepsView({super.key, required this.steps});

  @override
  Widget build(BuildContext context) {
    if (steps.isEmpty) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final running = steps.any((s) => s.running);
    final total = steps.fold<int>(0, (a, s) => a + s.ms);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: running,
          key: PageStorageKey('steps_${steps.length}_$running'),
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          dense: true,
          leading: running
              ? const SizedBox(
                  width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : Icon(Icons.check_circle_outline_rounded, size: 20, color: cs.primary),
          title: Text(
            running
                ? steps.lastWhere((s) => s.running).label
                : '${steps.length} step${steps.length == 1 ? '' : 's'}'
                    '${total > 0 ? ' · ${(total / 1000).toStringAsFixed(1)}s' : ''}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
          ),
          children: [for (final s in steps) _StepTile(step: s)],
        ),
      ),
    );
  }
}

class _StepTile extends StatelessWidget {
  final AgentStep step;
  const _StepTile({required this.step});

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).hintColor;
    final mono = TextStyle(fontFamily: 'monospace', fontSize: 12, color: muted);
    final argsText = const JsonEncoder.withIndent('  ').convert(step.args);
    return ExpansionTile(
      dense: true,
      tilePadding: const EdgeInsets.symmetric(horizontal: 6),
      childrenPadding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
      leading: step.running
          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
          : Icon(_iconFor(step.name), size: 18),
      title: Text(step.label,
          maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
      subtitle: step.running
          ? const Text('working…', style: TextStyle(fontSize: 11.5))
          : Text('${step.name}${step.ms > 0 ? ' · ${(step.ms / 1000).toStringAsFixed(1)}s' : ''}',
              style: const TextStyle(fontSize: 11.5)),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (step.args.isNotEmpty) ...[
          Text('Input', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: muted)),
          SelectableText(argsText, style: mono),
          const SizedBox(height: 8),
        ],
        if (!step.running) ...[
          Text('Result', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: muted)),
          SelectableText(step.result.isEmpty ? '(empty)' : step.result, style: mono),
        ],
      ],
    );
  }
}

// ── Files the agent produced: ![alt](nmfile:name) and [📎 name](nmfile:name) ──

const nmFileScheme = 'nmfile:';

Future<File?> agentFile(String name) async {
  final dir = await Get.find<AgentService>().filesDir();
  final n = name.split('/').last.split('\\').last;
  final f = File('${dir.path}/$n');
  return await f.exists() ? f : null;
}

/// Inline image for `![alt](nmfile:name)`.
Widget agentImage(Uri uri, String? alt) {
  final name = Uri.decodeComponent(uri.toString().substring(nmFileScheme.length));
  return FutureBuilder<File?>(
    future: agentFile(name),
    builder: (c, snap) {
      final f = snap.data;
      if (f == null) return Text(snap.connectionState == ConnectionState.done ? '[missing: $name]' : '');
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: GestureDetector(
          onTap: () => Share.shareXFiles([XFile(f.path)]),
          child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.file(f, fit: BoxFit.contain, height: 320)),
        ),
      );
    },
  );
}

/// Tapping a produced file: play audio, otherwise share / save it.
Future<void> openAgentFile(BuildContext context, String name) async {
  final f = await agentFile(Uri.decodeComponent(name));
  if (f == null) {
    Get.snackbar('File not found', name);
    return;
  }
  final ext = f.path.split('.').last.toLowerCase();
  if (['wav', 'mp3', 'm4a', 'ogg', 'aac', 'flac'].contains(ext)) {
    if (!context.mounted) return;
    await showModalBottomSheet(
        context: context, builder: (_) => _AudioSheet(file: f));
    return;
  }
  await Share.shareXFiles([XFile(f.path)]);
}

class _AudioSheet extends StatefulWidget {
  final File file;
  const _AudioSheet({required this.file});

  @override
  State<_AudioSheet> createState() => _AudioSheetState();
}

class _AudioSheetState extends State<_AudioSheet> {
  final _p = AudioPlayer();
  bool _playing = false;

  @override
  void initState() {
    super.initState();
    _p.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _playing = false);
    });
  }

  @override
  void dispose() {
    _p.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_playing) {
      await _p.pause();
    } else {
      await _p.play(DeviceFileSource(widget.file.path));
    }
    if (mounted) setState(() => _playing = !_playing);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(widget.file.path.split('/').last,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            FilledButton.icon(
              onPressed: _toggle,
              icon: Icon(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
              label: Text(_playing ? 'Pause' : 'Play'),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: () => Share.shareXFiles([XFile(widget.file.path)]),
              icon: const Icon(Icons.ios_share_rounded),
              label: const Text('Share / save'),
            ),
          ]),
        ]),
      ),
    );
  }
}
