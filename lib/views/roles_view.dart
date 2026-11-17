import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/chat_controller.dart';
import '../services/roles_service.dart';

/// Lists the roles (personas), lets the user add / edit / delete their own and
/// apply one to the current chat.
class RolesView extends StatelessWidget {
  const RolesView({super.key});

  @override
  Widget build(BuildContext context) {
    final svc = RolesService.ensure();
    return Scaffold(
      appBar: AppBar(title: const Text('Roles')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => editRole(context, null),
        icon: const Icon(Icons.add),
        label: const Text('New role'),
      ),
      body: Obx(() {
        final roles = svc.all;
        return ListView(padding: const EdgeInsets.fromLTRB(12, 8, 12, 96), children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(8, 4, 8, 12),
            child: Text(
                'A role is a set of instructions the AI follows in a chat (for example "Coder" or "Egyptian Arabic tutor"). Tap a role to use it in the current chat.'),
          ),
          for (final r in roles)
            Card(
              child: ListTile(
                leading: Text(r.emoji, style: const TextStyle(fontSize: 26)),
                title: Text(r.name),
                subtitle: Text(r.prompt, maxLines: 2, overflow: TextOverflow.ellipsis),
                onTap: () => applyRole(context, r),
                trailing: r.builtIn
                    ? null
                    : PopupMenuButton<String>(
                        onSelected: (v) async {
                          if (v == 'edit') await editRole(context, r);
                          if (v == 'delete') await svc.remove(r.id);
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'edit', child: Text('Edit')),
                          PopupMenuItem(value: 'delete', child: Text('Delete')),
                        ],
                      ),
              ),
            ),
        ]);
      }),
    );
  }
}

/// Puts the role's instructions on the current chat.
Future<void> applyRole(BuildContext context, AiRole r) async {
  final chat = Get.find<ChatController>();
  final id = chat.currentSessionId.value;
  if (id.isEmpty) {
    Get.snackbar('No chat open', 'Open or start a chat first, then pick a role.');
    return;
  }
  chat.setSessionSystemPrompt(id, r.prompt);
  Get.snackbar('Role applied', '${r.emoji} ${r.name} is now active in this chat.');
}

/// Bottom sheet to pick a role for the current chat.
Future<void> showRolePicker(BuildContext context) async {
  final svc = RolesService.ensure();
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: ListView(shrinkWrap: true, children: [
        for (final r in svc.all)
          ListTile(
            leading: Text(r.emoji, style: const TextStyle(fontSize: 24)),
            title: Text(r.name),
            onTap: () {
              Navigator.pop(ctx);
              applyRole(context, r);
            },
          ),
        ListTile(
          leading: const Icon(Icons.add),
          title: const Text('New role…'),
          onTap: () {
            Navigator.pop(ctx);
            editRole(context, null);
          },
        ),
      ]),
    ),
  );
}

Future<void> editRole(BuildContext context, AiRole? existing) async {
  final name = TextEditingController(text: existing?.name ?? '');
  final emoji = TextEditingController(text: existing?.emoji ?? '🎭');
  final prompt = TextEditingController(text: existing?.prompt ?? '');
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(existing == null ? 'New role' : 'Edit role'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            SizedBox(
                width: 64,
                child: TextField(
                    controller: emoji,
                    textAlign: TextAlign.center,
                    decoration: const InputDecoration(labelText: 'Icon'))),
            const SizedBox(width: 8),
            Expanded(
                child: TextField(
                    controller: name,
                    decoration: const InputDecoration(labelText: 'Name'))),
          ]),
          const SizedBox(height: 8),
          TextField(
              controller: prompt,
              minLines: 4,
              maxLines: 10,
              decoration: const InputDecoration(
                  labelText: 'Instructions',
                  hintText: 'You are … Always … Never …',
                  alignLabelWithHint: true)),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
      ],
    ),
  );
  if (ok != true || name.text.trim().isEmpty || prompt.text.trim().isEmpty) return;
  await RolesService.ensure().upsert(AiRole(
      id: existing?.id ?? RolesService.newId(),
      name: name.text.trim(),
      emoji: emoji.text.trim().isEmpty ? '🎭' : emoji.text.trim(),
      prompt: prompt.text.trim()));
}
