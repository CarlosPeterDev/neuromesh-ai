import 'dart:io' show File, FileSystemEntityType;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../core/ui.dart';
import '../controllers/chat_controller.dart';
import '../widgets/agent_steps.dart';
import '../services/chat_tool_service.dart';
import '../services/chat_tool_loop.dart';
import '../services/hive_service.dart';

class ChatToolsView extends StatefulWidget {
  const ChatToolsView({super.key});

  @override
  State<ChatToolsView> createState() => _ChatToolsViewState();
}

class _ChatToolsViewState extends State<ChatToolsView> {
  final _agent = Get.find<ChatToolService>();
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  static String _label(String p) => switch (p) {
        'allow' => 'Always allow',
        'block' => 'Blocked',
        _ => 'Always ask',
      };

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Scaffold(
      backgroundColor: t.bg,
      appBar: appScreenBar(context, title: 'Tools & permissions', showBack: true),
      body: ListView(padding: kPagePadding, children: [
        const SectionHeader('Tool use'),
        Obx(() => SwitchListTile(
          title: const Text('Let the model use tools'),
          subtitle: const Text('The model selects tools and searches to verify external facts.'),
          value: _agent.mode.value != ChatToolMode.off,
          onChanged: (enabled) => _agent.setMode(enabled ? ChatToolMode.auto : ChatToolMode.off),
        )),
        ListTile(
          title: const Text('Maximum tool executions per message'),
          trailing: DropdownButton<int>(
            value: (Get.find<HiveService>().getSetting<int>('chat_tool_step_limit') ?? 5).clamp(1, 10),
            items: [for (var steps = 1; steps <= 10; steps++)
              DropdownMenuItem(value: steps, child: Text('$steps'))],
            onChanged: (steps) async {
              if (steps == null) return;
              await Get.find<HiveService>().setSetting('chat_tool_step_limit', steps);
              if (mounted) setState(() {});
            },
          ),
        ),

        // ── memory ──
        const SectionHeader('Memory'),
        Obx(() => AppGroup(children: [
              for (final n in _agent.memory.toList())
                AppRow(
                  icon: Icons.notes_rounded,
                  title: n,
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(
                        tooltip: 'Edit',
                        icon: const Icon(Icons.edit_outlined, size: 18),
                        onPressed: () => _editNote(n)),
                    IconButton(
                        tooltip: 'Delete',
                        icon: const Icon(Icons.close_rounded, size: 18),
                        onPressed: () => _agent.removeNote(n)),
                  ]),
                ),
            ])),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _note,
              decoration: appInputDecoration(context, hint: 'Add a note the AI should remember'),
              onSubmitted: (_) => _addNote(),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filledTonal(onPressed: _addNote, icon: const Icon(Icons.add_rounded)),
        ]),
        Obx(() => _agent.memory.isEmpty
            ? const SizedBox.shrink()
            : Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                    onPressed: _agent.clearMemory, child: const Text('Clear all memory')))),

        _Workspace(agent: _agent),

        // ── permissions ──
        const SectionHeader('Permissions'),
        Text(
            'Choose what happens when the AI wants to use a tool. "Always ask" shows a confirmation each time.',
            style: t.caption),
        const SizedBox(height: 8),
        Obx(() => AppGroup(children: [
              for (final tool in _agent.catalog)
                if (ChatToolLoop.toolNames.contains(tool.name))
                _PolicyRow(
                  title: tool.name,
                  subtitle: tool.description,
                  value: _agent.policyFor('built-in', tool.name, needsConfirm: tool.needsConfirm),
                  onChanged: (v) => _agent.setPolicy('built-in', tool.name, v),
                ),
            ])),
        Obx(() => _agent.policy.isEmpty
            ? const SizedBox.shrink()
            : Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                    onPressed: _agent.resetPolicies,
                    child: const Text('Reset tool approvals')))),

      ]),
    );
  }

  void _addNote() {
    final v = _note.text.trim();
    if (v.isEmpty) return;
    _agent.addNote(v);
    _note.clear();
  }

  Future<void> _editNote(String old) async {
    final ctl = TextEditingController(text: old);
    await showAppSheet<void>(context, title: 'Edit note', builder: (ctx) {
      return Column(children: [
        TextField(controller: ctl, minLines: 2, maxLines: 6, decoration: appInputDecoration(ctx)),
        const SizedBox(height: 12),
        PrimaryButton(
            label: 'Save',
            onPressed: () {
              _agent.editNote(old, ctl.text);
              Navigator.pop(ctx);
            }),
      ]);
    });
    ctl.dispose();
  }

}

class _PolicyRow extends StatelessWidget {
  final String title;
  final String subtitle;
  final String value;
  final ValueChanged<String> onChanged;
  const _PolicyRow(
      {required this.title,
      required this.subtitle,
      required this.value,
      required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final color = switch (value) {
      'allow' => Colors.green,
      'block' => Colors.red,
      _ => Theme.of(context).hintColor,
    };
    return AppRow(
      title: title,
      subtitle: subtitle.length > 90 ? '${subtitle.substring(0, 90)}…' : subtitle,
      trailing: PopupMenuButton<String>(
        tooltip: 'Permission',
        initialValue: value,
        onSelected: onChanged,
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'ask', child: Text('Always ask')),
          PopupMenuItem(value: 'allow', child: Text('Always allow')),
          PopupMenuItem(value: 'block', child: Text('Block')),
        ],
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(_ChatToolsViewState._label(value),
                style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 13)),
            Icon(Icons.arrow_drop_down_rounded, color: color),
          ]),
        ),
      ),
    );
  }
}

class ChatWorkspaceView extends StatelessWidget {
  const ChatWorkspaceView({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: appScreenBar(context, title: 'Chat workspace', showBack: true),
        body: ListView(padding: kPagePadding, children: [
          _Workspace(agent: Get.find<ChatToolService>()),
        ]),
      );
}

class _Workspace extends StatefulWidget {
  final ChatToolService agent;
  const _Workspace({required this.agent});

  @override
  State<_Workspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends State<_Workspace> {
  List<FileSystemEntityInfo> _items = [];
  List<String> _archived = [];
  String? _error;
  late final _chat = Get.find<ChatController>();
  late String _chatId = _chat.currentSessionId.value;
  late String _project = widget.agent.projectForChat(_chatId);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final project = _project;
    try {
      final (items, archived) = await widget.agent.inProject(project, () async {
        final dir = await widget.agent.filesDir();
        final out = <FileSystemEntityInfo>[];
        await for (final f in dir.list(followLinks: false)) {
          if (f is! File) continue;
          final st = await f.stat();
          if (st.type != FileSystemEntityType.file) continue;
          out.add(FileSystemEntityInfo(f.path, f.uri.pathSegments.last, st.size));
        }
        out.sort((a, b) => a.name.compareTo(b.name));
        final archived = await widget.agent.archivedWorkspaceFiles();
        return (out, archived.where((name) => !out.any((item) => item.name == name)).toList());
      });
      if (mounted && _project == project) setState(() {
        _items = items;
        _archived = archived;
        _error = null;
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'The workspace could not be read.');
    }
  }

  Future<void> _chooseProject() async {
    var name = _project;
    final chosen = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Project workspace'),
        content: TextFormField(
          initialValue: name,
          maxLength: 60,
          decoration: const InputDecoration(
            labelText: 'Project name',
            helperText: 'Use the same name in related chats.',
          ),
          onChanged: (value) => name = value,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(dialog, ''), child: const Text('Use shared workspace')),
          FilledButton(onPressed: () => Navigator.pop(dialog, name.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (chosen == null || !mounted) return;
    if (_chatId.isEmpty && chosen.isNotEmpty) {
      _chat.createNewChat();
      _chatId = _chat.currentSessionId.value;
    }
    if (_chatId.isEmpty) return;
    await widget.agent.setChatProject(_chatId, chosen);
    if (!mounted) return;
    setState(() {
      _project = chosen;
      _items = [];
      _archived = [];
    });
    await _load();
  }

  Future<void> _history(String name) async {
    final project = _project;
    final versions = await widget.agent.inProject(project,
        () => widget.agent.workspaceVersions(name));
    if (!mounted) return;
    final selected = await showAppSheet<int>(
      context,
      title: name,
      subtitle: 'File versions',
      builder: (context) => versions.isEmpty
          ? const Text('No saved versions.')
          : Column(children: [
              for (final version in versions)
                ListTile(
                  title: Text(DateTime.fromMicrosecondsSinceEpoch(version).toLocal().toString().split('.').first),
                  trailing: const Icon(Icons.restore_rounded),
                  onTap: () => Navigator.pop(context, version),
                ),
            ]),
    );
    if (selected == null || !mounted) return;
    try {
      final restored = await widget.agent.inProject(project,
          () => widget.agent.restoreWorkspaceVersion(name, selected));
      if (mounted) showToast(restored ? 'File restored' : 'Version unavailable', name);
      await _load();
    } catch (_) {
      if (mounted) showToast('Could not restore the file', name, tone: ToastTone.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppGroup(children: [
      AppRow(
        icon: Icons.folder_open_outlined,
        title: _project.isEmpty ? 'Shared workspace' : _project,
        subtitle: 'Choose a project for this chat',
        onTap: _chooseProject,
      ),
      if (_error != null) AppNotice(_error!),
      for (final name in _archived)
        AppRow(
          icon: Icons.history_rounded,
          title: name,
          subtitle: 'Archived versions',
          onTap: () => _history(name),
        ),
      for (final f in _items)
        AppRow(
          icon: Icons.insert_drive_file_outlined,
          title: f.name,
          onTap: () => widget.agent.inProject(_project, () => openAgentFile(context, Uri.encodeComponent(f.name))),
          subtitle: '${(f.size / 1024).toStringAsFixed(f.size < 10240 ? 1 : 0)} KB · AI workspace',
          trailing: PopupMenuButton<String>(
            tooltip: 'File actions',
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'history', child: Text('File versions')),
              PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
            onSelected: (action) async {
              if (action == 'history') {
                await _history(f.name);
              } else {
                await widget.agent.inProject(_project, () => widget.agent.deleteWorkspaceFile(f.name));
                await _load();
              }
            },
          ),
        ),
      AppRow(
        icon: Icons.refresh_rounded,
        title: 'Refresh files',
        onTap: _load,
      ),
      AppRow(
        icon: Icons.upload_file_rounded,
        title: 'Add a file to the AI workspace',
        subtitle: 'Any type. The AI can read, search and transcribe it.',
        chevron: true,
        onTap: () async {
          final r = await FilePicker.pickFiles(type: FileType.any);
          final f = r?.files.single;
          if (f?.path == null) return;
          await widget.agent.inProject(_project, () => widget.agent.importToWorkspace(f!.path!, f.name));
          _load();
        },
      ),
    ]);
  }
}

class FileSystemEntityInfo {
  final String path;
  final String name;
  final int size;
  const FileSystemEntityInfo(this.path, this.name, this.size);
}
