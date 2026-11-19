import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../services/skills_service.dart';
import '../utils/skill_context.dart';

class SkillsView extends StatelessWidget {
  const SkillsView({super.key});
  Future<void> _edit(BuildContext context, SkillsService store,
      [SkillDefinition? skill]) async {
    final input = TextEditingController(
        text: skill?.source ??
            '---\nname: my-skill\ndescription: Describe when this skill should be used.\n---\n\n# Instructions\n');
    String? error;
    var saving = false;
    await showDialog<void>(
        context: context,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, setState) => AlertDialog(
                  title:
                      Text(skill == null ? 'New skill' : 'Edit ${skill.name}'),
                  content: SizedBox(
                      width: 600,
                      child: TextField(
                          controller: input,
                          minLines: 8,
                          maxLines: 18,
                          decoration: InputDecoration(
                              errorText: error,
                              border: const OutlineInputBorder()),
                          style: const TextStyle(fontFamily: 'monospace'))),
                  actions: [
                    TextButton(
                        onPressed: saving ? null : () => Navigator.pop(ctx),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: saving
                            ? null
                            : () async {
                                setState(() => saving = true);
                                try {
                                  await store.save(input.text,
                                      editing: skill?.name);
                                  if (ctx.mounted) Navigator.pop(ctx);
                                } catch (e) {
                                  if (ctx.mounted)
                                    setState(() {
                                      error = '$e';
                                      saving = false;
                                    });
                                }
                              },
                        child: const Text('Save'))
                  ],
                )));
    // The dialog route may still be animating out when its future completes.
  }

  @override
  Widget build(BuildContext context) {
    final store = Get.find<SkillsService>();
    return Scaffold(
        appBar: AppBar(title: const Text('Skills'), actions: [
          IconButton(
              tooltip: 'Create skill',
              icon: const Icon(Icons.add),
              onPressed: () => _edit(context, store))
        ]),
        body: Column(children: [
          const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                  'Import SKILL.md or a ZIP containing one skill and its resources. Mention @skill:name or @file:"path in workspace.md" in chat. Relevant enabled skills are selected automatically. Scripts use your existing tool permissions. Long documents are read in pages; a small model may still miss rules.')),
          Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: OutlinedButton.icon(
                  icon: const Icon(Icons.file_upload_outlined),
                  label: const Text('Import skill'),
                  onPressed: () async {
                    final result = await FilePicker.pickFiles(
                        type: FileType.custom,
                        allowedExtensions: ['md', 'zip']);
                    final path = result?.files.single.path;
                    if (path == null) return;
                    try {
                      await store.importFile(path);
                    } catch (e) {
                      if (context.mounted)
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                            content: Text('Could not import skill: $e')));
                    }
                  })),
          Expanded(
              child: Obx(() => store.skills.isEmpty
                  ? const Center(
                      child: Text('No skills yet. Create or import one.'))
                  : ListView(children: [
                      for (final skill in store.skills)
                        ListTile(
                          title: Text(skill.name),
                          subtitle: Text(skill.description,
                              maxLines: 3, overflow: TextOverflow.ellipsis),
                          onTap: () => _edit(context, store, skill),
                          trailing: Switch(
                              value: !store.disabled.contains(skill.name),
                              onChanged: (enabled) async {
                                try {
                                  await store.toggle(skill.name, enabled);
                                } catch (e) {
                                  if (context.mounted)
                                    ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(
                                            content:
                                                Text('Could not save: $e')));
                                }
                              }),
                        )
                    ]))),
        ]));
  }
}
