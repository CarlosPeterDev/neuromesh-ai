import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../core/ui.dart';
import '../services/agent_service.dart';
import '../services/mcp_client.dart';

class AgentView extends StatefulWidget {
  const AgentView({super.key});

  @override
  State<AgentView> createState() => _AgentViewState();
}

class _AgentViewState extends State<AgentView> {
  final _task = TextEditingController();
  late final AgentService _agent = Get.find<AgentService>();

  @override
  void dispose() {
    _task.dispose();
    super.dispose();
  }

  Future<void> _addPreset(String name, String url) async {
    if (_agent.servers.any((x) => x.url == url)) {
      Get.snackbar('Already added', name, snackPosition: SnackPosition.BOTTOM);
      return;
    }
    await _agent.addServer(name, url, '');
    Get.snackbar('Added $name', 'Check its status under MCP servers.',
        snackPosition: SnackPosition.BOTTOM);
  }

  Future<bool> _confirm(
      String tool, String server, Map<String, dynamic> args) async {
    if (!mounted) return false;
    final ok = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Allow this tool?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('The agent wants to run "$tool" on "$server". '
                'This sends the data below to that server.'),
            const SizedBox(height: 10),
            Text(args.isEmpty ? '(no arguments)' : args.toString(),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'deny'),
              child: const Text('Deny')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'always'),
              child: const Text('Always allow')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'once'),
              child: const Text('Allow once')),
        ],
      ),
    );
    if (ok == 'always') await _agent.allowAlwaysFor(server, tool);
    return ok == 'once' || ok == 'always';
  }

  void _start() {
    final text = _task.text.trim();
    if (text.isEmpty || _agent.isRunning.value) return;
    FocusScope.of(context).unfocus();
    _agent.run(text, _confirm);
  }

  void _openServerSheet({McpServerConfig? existing}) {
    final name = TextEditingController(text: existing?.name ?? '');
    final url = TextEditingController(text: existing?.url ?? '');
    final token = TextEditingController(text: existing?.token ?? '');
    showAppSheet<void>(
      context,
      title: existing == null ? 'Add MCP server' : existing.name,
      subtitle: 'Remote MCP servers over HTTP(S) only.',
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (existing == null) ...[
            TextField(
                controller: name,
                decoration: appInputDecoration(ctx, hint: 'Name')),
            const SizedBox(height: 10),
            TextField(
                controller: url,
                keyboardType: TextInputType.url,
                decoration:
                    appInputDecoration(ctx, hint: 'https://example.com/mcp')),
            const SizedBox(height: 10),
            TextField(
                controller: token,
                obscureText: true,
                decoration: appInputDecoration(ctx,
                    hint: 'Access token (optional)')),
            const SizedBox(height: 12),
            const AppNotice(
                'Tools you link can read what the agent sends them. You are asked before every call.'),
            const SizedBox(height: 16),
            PrimaryButton(
              label: 'Save and connect',
              onPressed: () {
                final u = url.text.trim();
                final uri = Uri.tryParse(u);
                if (name.text.trim().isEmpty ||
                    uri == null ||
                    !(uri.scheme == 'https' || uri.scheme == 'http') ||
                    uri.host.isEmpty) {
                  showToast('Check the details',
                      'Enter a name and a valid http(s) URL.',
                      tone: ToastTone.warning);
                  return;
                }
                Navigator.pop(ctx);
                _agent.addServer(name.text, u, token.text);
              },
            ),
          ] else ...[
            TonalButton.neutral(ctx, label: 'Reconnect and refresh tools',
                onTap: () {
              Navigator.pop(ctx);
              _agent.refreshServer(existing);
            }),
            const SizedBox(height: 10),
            TonalButton.destructive(ctx, label: 'Remove server', onTap: () {
              Navigator.pop(ctx);
              _agent.removeServer(existing.id);
            }),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Scaffold(
      backgroundColor: t.bg,
      appBar: appScreenBar(context, title: 'Agent'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          const AppNotice(
              'The agent uses your loaded local model. Small models may fail at multi-step tasks. MCP tools always ask before running.'),
          const SizedBox(height: 14),
          TextField(
            controller: _task,
            minLines: 2,
            maxLines: 5,
            textInputAction: TextInputAction.newline,
            decoration:
                appInputDecoration(context, hint: 'Describe a task for the agent'),
          ),
          const SizedBox(height: 10),
          Obx(() => _agent.isRunning.value
              ? TonalButton.destructive(context,
                  label: 'Stop', onTap: _agent.cancel)
              : PrimaryButton(
                  label: 'Run task',
                  icon: Icons.play_arrow_rounded,
                  onPressed: _start)),
          Obx(() {
            if (_agent.events.isEmpty) return const SizedBox.shrink();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SectionHeader('Progress'),
                for (final e in _agent.events) _eventTile(context, e),
              ],
            );
          }),
          const SectionHeader('Tools'),
          AppGroup(children: [
            const AppRow(
                icon: Icons.calculate_outlined,
                title: 'Calculator',
                subtitle: 'Built in · runs without asking'),
            const AppRow(
                icon: Icons.schedule_rounded,
                title: 'Current time',
                subtitle: 'Built in · runs without asking'),
            const AppRow(
                icon: Icons.folder_outlined,
                title: 'Files (private folder)',
                subtitle: 'List, read and write files inside the app only'),
            const AppRow(
                icon: Icons.public_rounded,
                title: 'Fetch web page',
                subtitle: 'Asks every time unless you choose Always allow'),
          ]),
          const SectionHeader('Memory'),
          Obx(() => AppGroup(children: [
                AppRow(
                    icon: Icons.psychology_outlined,
                    title: _agent.memory.isEmpty
                        ? 'No saved notes'
                        : '${_agent.memory.length} saved notes',
                    subtitle: _agent.memory.isEmpty
                        ? 'The agent can save notes with the remember tool.'
                        : _agent.memory.reversed.take(3).join(' · ')),
                if (_agent.memory.isNotEmpty)
                  AppRow(
                      icon: Icons.delete_outline,
                      title: 'Clear memory',
                      destructive: true,
                      onTap: _agent.clearMemory),
                if (_agent.alwaysAllow.isNotEmpty)
                  AppRow(
                      icon: Icons.lock_reset_rounded,
                      title:
                          'Reset "always allow" (${_agent.alwaysAllow.length})',
                      onTap: _agent.revokeAlways),
                AppRow(
                    icon: Icons.upload_file_rounded,
                    title: 'Give the agent a file',
                    subtitle: 'Copies it into the private folder',
                    onTap: () async {
                      final r = await FilePicker.pickFiles(withData: false);
                      final path = r?.files.single.path;
                      if (path == null) return;
                      final dest = File(
                          '${(await _agent.filesDir()).path}/${path.split('/').last}');
                      await File(path).copy(dest.path);
                      Get.snackbar('Added', path.split('/').last,
                          snackPosition: SnackPosition.BOTTOM);
                    }),
              ])),
          const SectionHeader('MCP presets (free, no key)'),
          AppGroup(children: [
            AppRow(
              icon: Icons.menu_book_rounded,
              title: 'DeepWiki',
              subtitle: 'Ask about public GitHub repos',
              onTap: () => _addPreset('DeepWiki', 'https://mcp.deepwiki.com/mcp'),
            ),
            AppRow(
              icon: Icons.library_books_outlined,
              title: 'Context7',
              subtitle: 'Up-to-date library documentation',
              onTap: () => _addPreset('Context7', 'https://mcp.context7.com/mcp'),
            ),
          ]),
          const SectionHeader('MCP servers'),
          Obx(() => AppGroup(children: [
                for (final s in _agent.servers)
                  AppRow(
                    icon: Icons.hub_outlined,
                    title: s.name,
                    subtitle: _agent.serverStatus[s.id] ?? 'Not connected yet',
                    trailing: Switch(
                      value: s.enabled,
                      onChanged: (v) => _agent.setEnabled(s.id, v),
                    ),
                    onTap: () => _openServerSheet(existing: s),
                  ),
                AppRow(
                  icon: Icons.add_rounded,
                  title: 'Add MCP server',
                  chevron: true,
                  onTap: () => _openServerSheet(),
                ),
              ])),
        ],
      ),
    );
  }

  Widget _eventTile(BuildContext context, AgentEvent e) {
    final t = AppTokens.of(context);
    final (icon, label) = switch (e.kind) {
      'task' => (Icons.flag_outlined, 'Task'),
      'model' => (Icons.psychology_alt_outlined, 'Model'),
      'tool_call' => (Icons.build_circle_outlined, 'Tool call'),
      'tool_result' => (Icons.subdirectory_arrow_right_rounded, 'Result'),
      'answer' => (Icons.check_circle_outline_rounded, 'Answer'),
      'error' => (Icons.error_outline_rounded, 'Error'),
      _ => (Icons.info_outline_rounded, 'Info'),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: t.muted),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: t.small),
                SelectableText(e.text, style: t.body),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
