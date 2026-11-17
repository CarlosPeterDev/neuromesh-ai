import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../core/ui.dart';
import '../services/agent_service.dart';
import '../services/memory_service.dart';

/// Everything the AI remembers about you. You can add, edit and delete notes,
/// and let the app keep them fresh by reading your recent chats now and then.
class MemoryView extends StatelessWidget {
  const MemoryView({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final agent = Get.find<AgentService>();
    final mem = MemoryService.ensure();
    return Scaffold(
      backgroundColor: t.bg,
      appBar: appScreenBar(context, title: 'Memory', showBack: true, actions: [
        PopupMenuButton<String>(
          onSelected: (v) async {
            if (v == 'clear') {
              final ok = await _confirm(context, 'Delete all memories?',
                  'The AI will forget everything saved here.');
              if (ok) {
                await agent.clearMemory();
                await mem.clearAutoMarks();
              }
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'clear', child: Text('Clear all')),
          ],
        ),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _editNote(context, agent, mem, null),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add memory'),
      ),
      body: Obx(() {
        final notes = agent.memory.toList();
        final next = mem.nextRun;
        return ListView(padding: kPagePadding, children: [
          const AppNotice(
              'These notes are added to every chat so the AI knows you. You can edit or delete any of them. '
              'Memory stays on this device.'),
          const SectionHeader('Automatic updates'),
          AppGroup(children: [
            AppRow(
              icon: Icons.auto_awesome_rounded,
              title: 'Auto-update memory',
              subtitle:
                  'Reads your new chat messages now and then and saves lasting facts about you. Needs a loaded model.',
              trailing: Switch(value: mem.enabled.value, onChanged: mem.setEnabled),
            ),
            if (mem.enabled.value)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: AppChips<int>(
                  items: MemoryService.intervals,
                  selected: mem.intervalHours.value,
                  onSelected: mem.setIntervalHours,
                ),
              ),
            AppRow(
              icon: Icons.edit_note_rounded,
              title: 'Save when I say "remember…"',
              subtitle: 'Messages like "remember that I use Flutter" are saved straight away.',
              trailing: Switch(value: agent.autoMemory.value, onChanged: agent.setAutoMemory),
            ),
          ]),
          const SizedBox(height: 10),
          if (mem.status.value.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
              child: Text(mem.status.value, style: t.label),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
            child: Text(
              mem.lastRunMs.value == 0
                  ? 'Never updated automatically.'
                  : 'Last update: ${_ago(mem.lastRunMs.value)}'
                      '${next != null && mem.enabled.value ? ' · next: ${_until(next)}' : ''}',
              style: t.label,
            ),
          ),
          const SizedBox(height: 6),
          PrimaryButton(
            label: mem.running.value ? 'Reading your chats…' : 'Update now',
            icon: Icons.refresh_rounded,
            busy: mem.running.value,
            onPressed: () => mem.updateNow(),
          ),
          SectionHeader('Saved memories (${notes.length}/${AgentService.maxMemory})'),
          if (notes.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(
                  child: Text(
                      'Nothing saved yet. Tap "Add memory", say "remember that …" in a chat, or turn on automatic updates.')),
            )
          else
            AppGroup(children: [
              for (final n in notes.reversed)
                AppRow(
                  icon: mem.isAuto(n) ? Icons.auto_awesome_rounded : Icons.push_pin_outlined,
                  title: n,
                  subtitle: mem.isAuto(n) ? 'Added automatically' : null,
                  onTap: () => _editNote(context, agent, mem, n),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline_rounded),
                    onPressed: () async {
                      await agent.removeNote(n);
                      await mem.unmarkAuto(n);
                    },
                  ),
                ),
            ]),
        ]);
      }),
    );
  }

  static String _ago(int ms) {
    final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    if (d.inDays < 1) return '${d.inHours} h ago';
    return '${d.inDays} d ago';
  }

  static String _until(DateTime t) {
    final d = t.difference(DateTime.now());
    if (d.isNegative) return 'soon';
    if (d.inHours < 1) return 'in ${d.inMinutes} min';
    if (d.inDays < 1) return 'in ${d.inHours} h';
    return 'in ${d.inDays} d';
  }

  static Future<bool> _confirm(BuildContext context, String title, String body) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
        ],
      ),
    );
    return r == true;
  }

  Future<void> _editNote(
      BuildContext context, AgentService agent, MemoryService mem, String? old) async {
    final c = TextEditingController(text: old ?? '');
    final saved = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(old == null ? 'Add memory' : 'Edit memory'),
        content: TextField(
          controller: c,
          autofocus: true,
          minLines: 2,
          maxLines: 5,
          maxLength: 300,
          decoration: appInputDecoration(ctx, hint: 'e.g. I build Android apps with Flutter'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    c.dispose();
    if (saved == null || saved.isEmpty) return;
    if (old == null) {
      await agent.addNote(saved);
    } else if (saved != old) {
      await agent.editNote(old, saved);
      await mem.unmarkAuto(old); // an edited note is now the user's own
    }
  }
}
