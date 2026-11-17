import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../services/sandbox_service.dart';
import 'scheduled_tasks_view.dart';
import 'package:get/get.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/ui.dart';
import '../services/agent_service.dart';
import '../services/mcp_client.dart';
import '../services/mcp_presets.dart';
import '../services/user_files.dart';
import '../utils/mcp_import.dart';
import '../services/mcp_oauth.dart';

/// Everything about what the chat AI may do: when it uses tools, what it
/// remembers, which folders it can see, per-tool permissions and MCP
/// connections. Opened from the chat screen; there is no separate agent page.
class ChatToolsView extends StatefulWidget {
  const ChatToolsView({super.key});

  @override
  State<ChatToolsView> createState() => _ChatToolsViewState();
}

class _ChatToolsViewState extends State<ChatToolsView> {
  final _agent = Get.find<AgentService>();
  final _files = Get.find<UserFilesService>();
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
        // ── when tools are used ──
        const SectionHeader('How the AI decides'),
        Obx(() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<AgentChatMode>(
                  segments: const [
                    ButtonSegment(value: AgentChatMode.auto, label: Text('Auto')),
                    ButtonSegment(value: AgentChatMode.always, label: Text('Always')),
                    ButtonSegment(value: AgentChatMode.off, label: Text('Off')),
                  ],
                  selected: {_agent.mode.value},
                  onSelectionChanged: (s) => _agent.setMode(s.first),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                switch (_agent.mode.value) {
                  AgentChatMode.auto =>
                    'Tools are offered when your message looks like it needs them (files, search, actions, attachments). Plain questions are answered straight away.',
                  AgentChatMode.always =>
                    'Tools are offered on every message. Uses more of the context window; small models may over-use them.',
                  AgentChatMode.off => 'The AI only chats. No tools, no file access.',
                },
                style: t.caption,
              ),
            ])),

        if (SandboxService.supported) ...[
          const SectionHeader('Linux sandbox (Pro build)'),
          const _SandboxCard(),
        ],

        // ── schedule ──
        const SectionHeader('Scheduled tasks'),
        AppGroup(children: [
          AppRow(
            icon: Icons.schedule_rounded,
            title: 'Run tasks on a schedule',
            subtitle: 'Daily news, reminders, reports: the AI does them by itself',
            chevron: true,
            onTap: () => Get.to(() => const ScheduledTasksView()),
          ),
        ]),

        // ── memory ──
        const SectionHeader('Memory'),
        Obx(() => AppGroup(children: [
              AppRow(
                icon: Icons.psychology_alt_rounded,
                title: 'Remember things automatically',
                subtitle: 'Say "remember that…" or let the AI save facts. Notes are added to every chat.',
                trailing: Switch(value: _agent.autoMemory.value, onChanged: _agent.setAutoMemory),
              ),
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

        // ── files ──
        const SectionHeader('Files the AI can see'),
        const AppNotice(
            'You choose the folders. Android shows its own picker, and the AI can only reach what is inside them. No storage permission is needed. Remove a folder any time.'),
        const SizedBox(height: 8),
        Obx(() => AppGroup(children: [
              for (final f in _files.folders.toList())
                AppRow(
                  icon: Icons.folder_open_rounded,
                  title: f.name,
                  subtitle: 'Shared with the AI',
                  trailing: IconButton(
                      tooltip: 'Stop sharing',
                      icon: const Icon(Icons.close_rounded, size: 18),
                      onPressed: () => _files.removeFolder(f)),
                ),
              AppRow(
                icon: Icons.create_new_folder_outlined,
                title: 'Share a folder…',
                chevron: true,
                onTap: () async {
                  try {
                    await _files.addFolder();
                  } catch (e) {
                    showToast('Could not open the picker', '$e', tone: ToastTone.error);
                  }
                },
              ),
            ])),
        const SizedBox(height: 8),
        _Workspace(agent: _agent),

        // ── permissions ──
        const SectionHeader('Permissions'),
        Text(
            'Choose what happens when the AI wants to use a tool. "Always ask" shows a confirmation each time.',
            style: t.caption),
        const SizedBox(height: 8),
        Obx(() => AppGroup(children: [
              for (final tool in _agent.catalog)
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
                    child: const Text('Reset all to defaults')))),

        // ── connections ──
        const SectionHeader('Connections (MCP)'),
        Text(
            'MCP servers give the AI extra tools: GitHub, databases, docs and more. Any server that speaks MCP over HTTPS works.',
            style: t.caption),
        const SizedBox(height: 8),
        Obx(() => AppGroup(children: [
              for (final s in _agent.servers.toList())
                AppRow(
                  icon: Icons.hub_outlined,
                  title: s.name,
                  subtitle: _agent.serverStatus[s.id] ?? (s.enabled ? 'Not connected yet' : 'Off'),
                  chevron: true,
                  onTap: () => _serverSheet(existing: s),
                ),
              AppRow(
                icon: Icons.storefront_outlined,
                title: 'Ready-made servers',
                subtitle: 'GitHub, Supabase, DeepWiki, Context7…',
                chevron: true,
                onTap: _presets,
              ),
              AppRow(
                icon: Icons.content_paste_rounded,
                title: 'Paste a config or URL',
                subtitle: 'The standard mcpServers JSON, or just a link',
                chevron: true,
                onTap: _paste,
              ),
              AppRow(
                icon: Icons.add_link_rounded,
                title: 'Add a server by hand',
                chevron: true,
                onTap: () => _serverSheet(),
              ),
            ])),
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

  // ── MCP ──

  Future<void> _presets() async {
    await showAppSheet<void>(context, title: 'Ready-made servers', builder: (ctx) {
      return AppGroup(children: [
        for (final p in kMcpPresets)
          AppRow(
            icon: p.unsupported != null ? Icons.block_rounded : Icons.hub_outlined,
            title: p.name,
            subtitle: p.blurb,
            chevron: true,
            onTap: () {
              Navigator.pop(ctx);
              _presetSheet(p);
            },
          ),
      ]);
    });
  }

  Future<void> _presetSheet(McpPreset p) async {
    final token = TextEditingController();
    final fields = {for (final f in p.fields) f.key: TextEditingController()};
    String? error;
    var busy = false;
    await showAppSheet<void>(context, title: p.name, subtitle: p.blurb, builder: (ctx) {
      return StatefulBuilder(builder: (ctx, setS) {
        if (p.unsupported != null) return AppNotice(p.unsupported!, icon: Icons.info_outline_rounded);
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (p.tokenLabel != null) ...[
            TextField(
              controller: token,
              obscureText: true,
              decoration: appInputDecoration(ctx, label: p.tokenLabel),
            ),
            if (p.tokenHelp != null) ...[
              const SizedBox(height: 6),
              Text(p.tokenHelp!, style: AppTokens.of(ctx).caption),
            ],
            if (p.tokenUrl != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                    onPressed: () => launchUrl(Uri.parse(p.tokenUrl!),
                        mode: LaunchMode.externalApplication),
                    child: const Text('Get a token')),
              ),
          ],
          OutlinedButton.icon(
            icon: const Icon(Icons.login_rounded),
            label: const Text('Sign in with browser instead (no token)'),
            onPressed: busy
                ? null
                : () async {
                    final u = presetUrl(p, {for (final e in fields.entries) e.key: e.value.text});
                    setS(() {
                      busy = true;
                      error = null;
                    });
                    try {
                      await McpOAuth.signIn(u);
                      final cfg = McpServerConfig(id: 'test', name: p.name, url: u, token: '');
                      final tools = await _agent.testServer(cfg);
                      await _agent.addServer(cfg.name, cfg.url, '');
                      if (ctx.mounted) Navigator.pop(ctx);
                      showToast('Connected', '${p.name}: ${tools.length} tools', tone: ToastTone.success);
                    } catch (e) {
                      setS(() {
                        busy = false;
                        error = '$e';
                      });
                    }
                  },
          ),
          for (final f in p.fields) ...[
            const SizedBox(height: 8),
            TextField(
                controller: fields[f.key],
                decoration: appInputDecoration(ctx, label: f.label, hint: f.hint)),
          ],
          if (error != null) ...[
            const SizedBox(height: 8),
            AppNotice(error!, icon: Icons.error_outline_rounded, color: Colors.red),
          ],
          const SizedBox(height: 14),
          PrimaryButton(
            label: 'Connect',
            busy: busy,
            onPressed: () async {
              if (p.tokenLabel != null &&
                  token.text.trim().isEmpty &&
                  !McpOAuth.hasTokens(presetUrl(p, {for (final e in fields.entries) e.key: e.value.text}))) {
                setS(() => error = 'Paste a token, or use "Sign in with browser".');
                return;
              }
              final cfg = McpServerConfig(
                id: 'test',
                name: p.name,
                url: presetUrl(p, {for (final e in fields.entries) e.key: e.value.text}),
                token: token.text.trim(),
              );
              setS(() {
                busy = true;
                error = null;
              });
              try {
                final tools = await _agent.testServer(cfg);
                await _agent.addServer(cfg.name, cfg.url, cfg.token);
                if (ctx.mounted) Navigator.pop(ctx);
                showToast('Connected', '${p.name}: ${tools.length} tools', tone: ToastTone.success);
              } catch (e) {
                setS(() {
                  busy = false;
                  error = '$e';
                });
              }
            },
          ),
        ]);
      });
    });
    token.dispose();
    for (final c in fields.values) {
      c.dispose();
    }
  }

  Future<void> _paste() async {
    final ctl = TextEditingController();
    String? msg;
    await showAppSheet<void>(context, title: 'Paste a config or URL', builder: (ctx) {
      return StatefulBuilder(builder: (ctx, setS) {
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(
            controller: ctl,
            minLines: 5,
            maxLines: 10,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
            decoration: appInputDecoration(ctx,
                hint: '{"mcpServers":{"name":{"url":"https://…","headers":{"Authorization":"Bearer …"}}}}'),
          ),
          if (msg != null) ...[
            const SizedBox(height: 8),
            AppNotice(msg!),
          ],
          const SizedBox(height: 12),
          PrimaryButton(
            label: 'Add',
            onPressed: () async {
              final r = parseMcpConfig(ctl.text);
              if (r.servers.isEmpty) {
                setS(() => msg = r.skipped.isEmpty
                    ? 'Nothing to add.'
                    : 'Could not use: ${r.skipped.join('; ')}');
                return;
              }
              for (final s in r.servers) {
                await _agent.addServer(s.name, s.url, '', headers: s.headers);
              }
              if (ctx.mounted) Navigator.pop(ctx);
              showToast('Added ${r.servers.length}',
                  r.skipped.isEmpty ? 'Connecting…' : 'Skipped: ${r.skipped.join('; ')}',
                  tone: ToastTone.success);
            },
          ),
        ]);
      });
    });
    ctl.dispose();
  }

  Future<void> _serverSheet({McpServerConfig? existing}) async {
    final name = TextEditingController(text: existing?.name ?? '');
    final url = TextEditingController(text: existing?.url ?? '');
    final token = TextEditingController(text: existing?.token ?? '');
    final headers = TextEditingController(
        text: existing == null
            ? ''
            : existing.headers.entries.map((e) => '${e.key}: ${e.value}').join('\n'));
    String? result;
    var ok = false;
    var busy = false;

    Map<String, String> parseHeaders() {
      final out = <String, String>{};
      for (final line in headers.text.split('\n')) {
        final i = line.indexOf(':');
        if (i > 0) out[line.substring(0, i).trim()] = line.substring(i + 1).trim();
      }
      return out;
    }

    McpServerConfig build() => McpServerConfig(
          id: existing?.id ?? 'test',
          name: name.text.trim().isEmpty ? 'Server' : name.text.trim(),
          url: url.text.trim(),
          token: token.text.trim(),
          enabled: existing?.enabled ?? true,
          headers: parseHeaders(),
          disabledTools: existing?.disabledTools ?? const {},
        );

    await showAppSheet<void>(
        context,
        title: existing == null ? 'Add a server' : existing.name,
        builder: (ctx) {
      return StatefulBuilder(builder: (ctx, setS) {
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(controller: name, decoration: appInputDecoration(ctx, label: 'Name')),
          const SizedBox(height: 8),
          TextField(
              controller: url,
              keyboardType: TextInputType.url,
              decoration: appInputDecoration(ctx, label: 'Server URL', hint: 'https://…/mcp')),
          const SizedBox(height: 8),
          TextField(
              controller: token,
              obscureText: true,
              decoration: appInputDecoration(ctx, label: 'Bearer token (optional)')),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.login_rounded, size: 18),
              label: Text(McpOAuth.hasTokens(url.text.trim())
                  ? 'Signed in · sign in again'
                  : 'Sign in with browser (no token)'),
              onPressed: busy
                  ? null
                  : () async {
                      final u = url.text.trim();
                      if (u.isEmpty) {
                        setS(() {
                          ok = false;
                          result = 'Enter the server URL first.';
                        });
                        return;
                      }
                      setS(() {
                        busy = true;
                        ok = true;
                        result = 'Opening your browser…';
                      });
                      try {
                        await McpOAuth.signIn(u, onStatus: (m) => setS(() => result = m));
                        final tools = await _agent.testServer(build());
                        setS(() {
                          ok = true;
                          result = 'Signed in. ${tools.length} tools available.';
                        });
                      } catch (e) {
                        setS(() {
                          ok = false;
                          result = '$e';
                        });
                      } finally {
                        setS(() => busy = false);
                      }
                    },
            ),
          ),
          const SizedBox(height: 4),
          TextField(
              controller: headers,
              minLines: 1,
              maxLines: 4,
              decoration: appInputDecoration(ctx,
                  label: 'Other headers (optional)', hint: 'Header-Name: value, one per line')),
          if (result != null) ...[
            const SizedBox(height: 8),
            AppNotice(result!,
                icon: ok ? Icons.check_circle_outline_rounded : Icons.error_outline_rounded,
                color: ok ? Colors.green : Colors.red),
          ],
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: busy
                    ? null
                    : () async {
                        setS(() {
                          busy = true;
                          result = null;
                        });
                        try {
                          final tools = await _agent.testServer(build());
                          setS(() {
                            ok = true;
                            result = 'Works: ${tools.length} tools (${tools.take(4).map((e) => e.name).join(', ')}${tools.length > 4 ? '…' : ''})';
                          });
                        } catch (e) {
                          setS(() {
                            ok = false;
                            result = '$e';
                          });
                        } finally {
                          setS(() => busy = false);
                        }
                      },
                child: const Text('Test'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton(
                onPressed: () async {
                  final cfg = build();
                  if (cfg.url.isEmpty) {
                    setS(() {
                      ok = false;
                      result = 'Enter the server URL.';
                    });
                    return;
                  }
                  if (existing == null) {
                    await _agent.addServer(cfg.name, cfg.url, cfg.token, headers: cfg.headers);
                  } else {
                    await _agent.updateServer(cfg);
                  }
                  if (ctx.mounted) Navigator.pop(ctx);
                },
                child: Text(existing == null ? 'Add' : 'Save'),
              ),
            ),
          ]),
          if (existing != null) ...[
            const SizedBox(height: 16),
            Obx(() {
              if (_agent.toolsVersion.value < 0) return const SizedBox.shrink(); // rebuilds when tools change
              final tools = _agent.toolsOf(existing.id);
              final s = _agent.servers.firstWhereOrNull((x) => x.id == existing.id) ?? existing;
              return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                AppRow(
                  icon: Icons.power_settings_new_rounded,
                  title: 'Enabled',
                  trailing: Switch(
                      value: s.enabled, onChanged: (v) => _agent.setEnabled(existing.id, v)),
                ),
                if (tools.isNotEmpty) ...[
                  const SectionHeader('Tools'),
                  AppGroup(children: [
                    for (final tl in tools)
                      _PolicyRow(
                        title: tl.name,
                        subtitle: tl.description,
                        value: s.disabledTools.contains(tl.name)
                            ? 'block'
                            : _agent.policyFor(s.name, tl.name, needsConfirm: true),
                        onChanged: (v) async {
                          if (v == 'block') {
                            await _agent.setToolEnabled(existing.id, tl.name, false);
                          } else {
                            await _agent.setToolEnabled(existing.id, tl.name, true);
                            await _agent.setPolicy(s.name, tl.name, v);
                          }
                        },
                      ),
                  ]),
                ],
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () async {
                    await _agent.removeServer(existing.id);
                    if (ctx.mounted) Navigator.pop(ctx);
                  },
                  child: const Text('Remove this server', style: TextStyle(color: Colors.red)),
                ),
              ]);
            }),
          ],
        ]);
      });
    });
    name.dispose();
    url.dispose();
    token.dispose();
    headers.dispose();
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

/// Files in the AI's private workspace (attachments land here too).
class _Workspace extends StatefulWidget {
  final AgentService agent;
  const _Workspace({required this.agent});

  @override
  State<_Workspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends State<_Workspace> {
  List<FileSystemEntityInfo> _items = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final dir = await widget.agent.filesDir();
    final out = <FileSystemEntityInfo>[];
    for (final f in dir.listSync()) {
      final st = f.statSync();
      out.add(FileSystemEntityInfo(f.path, f.path.split('/').last, st.size));
    }
    out.sort((a, b) => a.name.compareTo(b.name));
    if (mounted) setState(() => _items = out);
  }

  @override
  Widget build(BuildContext context) {
    return AppGroup(children: [
      for (final f in _items)
        AppRow(
          icon: Icons.insert_drive_file_outlined,
          title: f.name,
          subtitle: '${(f.size / 1024).toStringAsFixed(f.size < 10240 ? 1 : 0)} KB · AI workspace',
          trailing: IconButton(
              tooltip: 'Delete',
              icon: const Icon(Icons.delete_outline_rounded, size: 18),
              onPressed: () async {
                await widget.agent.deleteWorkspaceFile(f.name);
                _load();
              }),
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
          await widget.agent.importToWorkspace(f!.path!, f.name);
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


class _SandboxCard extends StatelessWidget {
  const _SandboxCard();

  @override
  Widget build(BuildContext context) {
    final sb = Get.find<SandboxService>();
    return Obx(() => AppGroup(children: [
          AppRow(
            icon: Icons.terminal_rounded,
            title: sb.installed.value ? 'Alpine Linux is installed' : 'Install Alpine Linux',
            subtitle: sb.busy.value
                ? sb.status.value
                : sb.installed.value
                    ? 'The AI can run commands, create files and deploy from here'
                    : 'About 4 MB download. Lets the AI run real commands (python, node, git, curl…).',
            trailing: sb.busy.value
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : sb.installed.value
                    ? IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => sb.uninstall())
                    : IconButton(
                        icon: const Icon(Icons.download_rounded),
                        onPressed: () async {
                          try {
                            await sb.install();
                          } catch (e) {
                            Get.snackbar('Install failed', '$e'.replaceFirst('Exception: ', ''));
                          }
                        }),
          ),
        ]));
  }
}
