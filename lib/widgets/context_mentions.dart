import 'dart:io';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../controllers/chat_controller.dart';
import '../services/agent_service.dart';
import '../services/skills_service.dart';

/// Explicit picker so skills and files are discoverable without memorising syntax.
class ContextMentionButton extends StatelessWidget {
  final ChatController controller;
  const ContextMentionButton({super.key, required this.controller});
  Future<void> _pick(BuildContext context) async {
    final agent = Get.find<AgentService>();
    final choices = <(String, String)>[
      if (Get.isRegistered<SkillsService>())
        for (final s in Get.find<SkillsService>().skills)
          if (!Get.find<SkillsService>().disabled.contains(s.name))
            ('@skill:${s.name}', s.description),
    ];
    try {
      final project = agent.projectForChat(controller.currentSessionId.value);
      final dir = await agent.inProject(project, agent.filesDir);
      var count = 0;
      await for (final file in dir.list(recursive: true, followLinks: false)) {
        if (++count > 1000) break;
        if (file is! File) continue;
        final name = file.path
            .substring(dir.path.length + 1)
            .replaceAll(Platform.pathSeparator, '/');
        choices.add(('@file:"$name"', 'Workspace file'));
      }
    } catch (e) {
      if (context.mounted)
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not list workspace files: $e')));
    }
    if (!context.mounted) return;
    var query = '';
    final selected = await showDialog<String>(
        context: context,
        builder: (ctx) => StatefulBuilder(builder: (ctx, update) {
              final shown = choices
                  .where((c) => '${c.$1} ${c.$2}'
                      .toLowerCase()
                      .contains(query.toLowerCase()))
                  .toList();
              return AlertDialog(
                  title: const Text('Mention a skill or file'),
                  content: SizedBox(
                      width: 560,
                      height: 360,
                      child: Column(children: [
                        TextField(
                            autofocus: true,
                            decoration: const InputDecoration(
                                hintText: 'Search skills and workspace files'),
                            onChanged: (v) => update(() => query = v)),
                        Expanded(
                            child: shown.isEmpty
                                ? const Center(
                                    child: Text(
                                        'No matches. Add skills in Settings → Skills, or attach a file to this chat.'))
                                : ListView.builder(
                                    itemCount: shown.length,
                                    itemBuilder: (ctx, i) => ListTile(
                                          title: Text(shown[i].$1),
                                          subtitle: Text(shown[i].$2,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis),
                                          onTap: () =>
                                              Navigator.pop(ctx, shown[i].$1),
                                        ))),
                      ])),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('Cancel'))
                  ]);
            }));
    if (selected == null) return;
    final text = controller.textController;
    final selection = text.selection;
    final start = selection.isValid ? selection.start : text.text.length;
    final end = selection.isValid ? selection.end : start;
    final insert = '$selected ';
    text.value = TextEditingValue(
        text: text.text.replaceRange(start, end, insert),
        selection: TextSelection.collapsed(offset: start + insert.length));
    controller.inputText.value = text.text;
    controller.inputFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) => IconButton(
      tooltip: 'Mention a skill or file',
      icon: const Icon(Icons.alternate_email, size: 21),
      onPressed: () => _pick(context));
}
