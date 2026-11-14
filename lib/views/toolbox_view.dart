import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/chat_controller.dart';
import '../core/ui.dart';
import '../services/toolbox_service.dart';

class ToolboxView extends StatelessWidget {
  const ToolboxView({super.key});

  ToolboxService get _tb => Get.find<ToolboxService>();

  void _toast(String m) => Get.snackbar('NeuroMesh', m,
      snackPosition: SnackPosition.BOTTOM, margin: const EdgeInsets.all(12));

  Future<String?> _ask(BuildContext c, String title, String hint,
      {int lines = 1}) {
    final ctl = TextEditingController();
    return showDialog<String>(
      context: c,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
            controller: ctl,
            maxLines: lines,
            autofocus: true,
            decoration: InputDecoration(hintText: hint)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Scaffold(
      backgroundColor: t.bg,
      appBar: appScreenBar(context, title: 'Toolbox'),
      body: ListView(padding: kPagePadding, children: [
        const SectionHeader('Roles'),
        AppGroup(dividerIndent: 60, children: [
          for (final r in kRolePresets)
            AppRow(
              leading: Text(r.emoji, style: const TextStyle(fontSize: 22)),
              title: r.name,
              subtitle: r.prompt,
              onTap: () async {
                await _tb.applyRole(r);
                _toast('Role "${r.name}" is now the system prompt.');
              },
            ),
        ]),
        const SectionHeader('Prompt library'),
        Obx(() => AppGroup(dividerIndent: 60, children: [
              for (final p in _tb.prompts)
                AppRow(
                  icon: Icons.bolt_outlined,
                  title: '${p['title']}',
                  subtitle: '${p['text']}'.trim(),
                  onTap: () {
                    _tb.usePrompt('${p['text']}');
                    Get.back();
                    _toast('Prompt placed in the chat box.');
                  },
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, size: 20),
                    onPressed: () => _tb.removePrompt('${p['id']}'),
                  ),
                ),
              AppRow(
                icon: Icons.add_rounded,
                title: 'Add prompt',
                onTap: () async {
                  final title = await _ask(context, 'Prompt name', 'e.g. Email reply');
                  if (title == null || title.isEmpty || !context.mounted) return;
                  final text = await _ask(context, 'Prompt text', 'The text to insert', lines: 4);
                  if (text == null || text.isEmpty) return;
                  await _tb.addPrompt(title, text);
                },
              ),
            ])),
        const SectionHeader('Model profiles'),
        Obx(() => AppGroup(dividerIndent: 60, children: [
              for (final p in _tb.profiles)
                AppRow(
                  icon: Icons.tune_rounded,
                  title: '${p['name']}',
                  subtitle:
                      'temp ${p['temperature']} · ${p['maxTokens']} tokens · ctx ${p['contextSize']}',
                  onTap: () async {
                    await _tb.applyProfile(p);
                    _toast('Profile "${p['name']}" applied. Reload the model to use the new context size.');
                  },
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, size: 20),
                    onPressed: () => _tb.removeProfile('${p['id']}'),
                  ),
                ),
              AppRow(
                icon: Icons.add_rounded,
                title: 'Save current settings as profile',
                onTap: () async {
                  final n = await _ask(context, 'Profile name', 'e.g. Fast & short');
                  if (n == null || n.isEmpty) return;
                  await _tb.saveProfile(n);
                },
              ),
            ])),
        const SectionHeader('Chats & data'),
        AppGroup(dividerIndent: 60, children: [
          AppRow(
            icon: Icons.ios_share_rounded,
            title: 'Export this chat (Markdown)',
            onTap: () => _exportCurrent(true),
          ),
          AppRow(
            icon: Icons.data_object_rounded,
            title: 'Export this chat (JSON)',
            onTap: () => _exportCurrent(false),
          ),
          AppRow(
            icon: Icons.file_open_outlined,
            title: 'Import a chat (JSON)',
            onTap: () async => _toast(await _tb.importChat()),
          ),
          AppRow(
            icon: Icons.backup_outlined,
            title: 'Back up everything',
            subtitle: 'Chats and settings. API keys are never included.',
            onTap: () => _tb.createBackup(),
          ),
          AppRow(
            icon: Icons.restore_rounded,
            title: 'Restore from backup',
            onTap: () async => _toast(await _tb.restoreBackup()),
          ),
        ]),
      ]),
    );
  }

  Future<void> _exportCurrent(bool md) async {
    final id = Get.find<ChatController>().currentSessionId.value;
    if (id.isEmpty) {
      _toast('Open a chat first.');
      return;
    }
    try {
      await _tb.exportChat(id, markdown: md);
    } catch (_) {
      _toast('Nothing to export yet. Send a message first.');
    }
  }
}
