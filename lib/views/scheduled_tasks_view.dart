import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:uuid/uuid.dart';

import '../core/ui.dart';
import '../services/scheduler_service.dart';

/// Tasks the app runs by itself on a schedule.
class ScheduledTasksView extends StatelessWidget {
  const ScheduledTasksView({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final s = Get.find<SchedulerService>();
    return Scaffold(
      backgroundColor: t.bg,
      appBar: appScreenBar(context, title: 'Scheduled tasks'),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context, s, null),
        icon: const Icon(Icons.add_alarm_rounded),
        label: const Text('New task'),
      ),
      body: Obx(() => ListView(padding: kPagePadding, children: [
            const AppNotice(
                'The app runs these by itself, using your loaded chat model and all the tools you allowed. '
                'While the app is open they run on time. If it is closed you get a notification at that time; tap it and the task runs. '
                'Each run appears as a new chat.'),
            const SizedBox(height: 8),
            if (s.tasks.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(
                    child: Text('No tasks yet. Tap "New task", or ask the AI: "every morning at 8 summarise AI news".')),
              )
            else
              AppGroup(children: [
                for (final k in s.tasks.toList())
                  AppRow(
                    icon: s.running.value == k.id ? Icons.sync_rounded : Icons.schedule_rounded,
                    title: k.title,
                    subtitle:
                        '${k.whenText}${k.lastRun > 0 ? '\nLast run: ${_ago(k.lastRun)}' : ''}',
                    onTap: () => _edit(context, s, k),
                    trailing: Switch(value: k.enabled, onChanged: (v) => s.setEnabled(k.id, v)),
                  ),
              ]),
          ])),
    );
  }

  static String _ago(int ms) {
    final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    if (d.inDays < 1) return '${d.inHours} h ago';
    return '${d.inDays} d ago';
  }

  Future<void> _edit(BuildContext context, SchedulerService s, ScheduledTask? existing) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => _TaskEditor(s: s, existing: existing),
    );
  }
}

class _TaskEditor extends StatefulWidget {
  final SchedulerService s;
  final ScheduledTask? existing;
  const _TaskEditor({required this.s, this.existing});

  @override
  State<_TaskEditor> createState() => _TaskEditorState();
}

class _TaskEditorState extends State<_TaskEditor> {
  late final _title = TextEditingController(text: widget.existing?.title ?? '');
  late final _prompt = TextEditingController(text: widget.existing?.prompt ?? '');
  late String _kind = widget.existing?.kind ?? 'daily';
  late TimeOfDay _time = TimeOfDay(
      hour: widget.existing?.hour ?? 8, minute: widget.existing?.minute ?? 0);
  late final Set<int> _days = {...(widget.existing?.days ?? [1, 2, 3, 4, 5])};
  late final _every = TextEditingController(text: '${widget.existing?.everyMin ?? 60}');
  late DateTime _once = widget.existing != null && widget.existing!.onceAt > 0
      ? DateTime.fromMillisecondsSinceEpoch(widget.existing!.onceAt)
      : DateTime.now().add(const Duration(hours: 1));

  void _save() {
    final prompt = _prompt.text.trim();
    if (prompt.isEmpty) {
      Get.snackbar('Missing prompt', 'Write what the AI should do.');
      return;
    }
    final old = widget.existing;
    final task = ScheduledTask(
      id: old?.id ?? const Uuid().v4(),
      title: _title.text.trim().isEmpty
          ? (prompt.length > 32 ? '${prompt.substring(0, 32)}…' : prompt)
          : _title.text.trim(),
      prompt: prompt,
      kind: _kind,
      hour: _time.hour,
      minute: _time.minute,
      days: _days.isEmpty ? [1, 2, 3, 4, 5, 6, 7] : _days.toList(),
      everyMin: int.tryParse(_every.text) ?? 60,
      onceAt: _once.millisecondsSinceEpoch,
      enabled: old?.enabled ?? true,
      lastRun: old?.lastRun ?? 0,
      lastResult: old?.lastResult ?? '',
      anchor: DateTime.now().millisecondsSinceEpoch,
    );
    widget.s.upsert(task);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final old = widget.existing;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.of(context).viewInsets.bottom + 16),
      child: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(
              controller: _title,
              decoration: appInputDecoration(context, hint: 'Name (optional)')),
          const SizedBox(height: 8),
          TextField(
              controller: _prompt,
              minLines: 2,
              maxLines: 6,
              decoration: appInputDecoration(context,
                  hint: 'What should the AI do? e.g. Search the web for today\'s AI news and summarise it')),
          const SizedBox(height: 12),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'once', label: Text('Once')),
              ButtonSegment(value: 'daily', label: Text('Daily')),
              ButtonSegment(value: 'weekly', label: Text('Weekly')),
              ButtonSegment(value: 'every', label: Text('Every')),
            ],
            selected: {_kind},
            onSelectionChanged: (v) => setState(() => _kind = v.first),
          ),
          const SizedBox(height: 8),
          if (_kind == 'every')
            TextField(
                controller: _every,
                keyboardType: TextInputType.number,
                decoration: appInputDecoration(context, hint: 'Minutes between runs'))
          else if (_kind == 'once')
            OutlinedButton.icon(
              icon: const Icon(Icons.event_rounded),
              label: Text('${_once.year}-${_once.month.toString().padLeft(2, '0')}-${_once.day.toString().padLeft(2, '0')} '
                  '${_once.hour.toString().padLeft(2, '0')}:${_once.minute.toString().padLeft(2, '0')}'),
              onPressed: () async {
                final d = await showDatePicker(
                    context: context,
                    initialDate: _once,
                    firstDate: DateTime.now(),
                    lastDate: DateTime.now().add(const Duration(days: 730)));
                if (d == null || !mounted) return;
                final tm = await showTimePicker(
                    context: context, initialTime: TimeOfDay.fromDateTime(_once));
                if (tm == null) return;
                setState(() => _once = DateTime(d.year, d.month, d.day, tm.hour, tm.minute));
              },
            )
          else ...[
            OutlinedButton.icon(
              icon: const Icon(Icons.access_time_rounded),
              label: Text(_time.format(context)),
              onPressed: () async {
                final tm = await showTimePicker(context: context, initialTime: _time);
                if (tm != null) setState(() => _time = tm);
              },
            ),
            if (_kind == 'weekly')
              Wrap(spacing: 6, children: [
                for (var i = 0; i < 7; i++)
                  FilterChip(
                    label: Text(names[i]),
                    selected: _days.contains(i + 1),
                    onSelected: (v) =>
                        setState(() => v ? _days.add(i + 1) : _days.remove(i + 1)),
                  ),
              ]),
          ],
          const SizedBox(height: 12),
          Row(children: [
            if (old != null) ...[
              TextButton(
                  onPressed: () {
                    widget.s.remove(old.id);
                    Navigator.pop(context);
                  },
                  child: const Text('Delete')),
              TextButton(
                  onPressed: () {
                    Navigator.pop(context);
                    widget.s.runNow(old);
                  },
                  child: const Text('Run now')),
              if (old.lastResult.isNotEmpty)
                TextButton(
                    onPressed: () => showDialog(
                        context: context,
                        builder: (_) => AlertDialog(
                            title: Text(old.title),
                            content: SingleChildScrollView(child: SelectableText(old.lastResult)))),
                    child: const Text('Last result')),
            ],
            const Spacer(),
            FilledButton(onPressed: _save, child: const Text('Save')),
          ]),
        ]),
      ),
    );
  }
}
