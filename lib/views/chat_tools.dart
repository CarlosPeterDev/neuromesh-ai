import 'dart:io' show File, FileSystemEntityType;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../services/desktop_command_service.dart';
import 'desktop_access_view.dart';
import '../services/sandbox_service.dart';
import 'scheduled_tasks_view.dart';
import 'package:get/get.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/ui.dart';
import '../controllers/chat_controller.dart';
import '../widgets/agent_steps.dart';
import '../widgets/device_access_status.dart';
import '../services/agent_service.dart';
import '../services/inference_service.dart';
import '../services/cloud_service.dart';
import '../controllers/settings_controller.dart';
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
      appBar:
          appScreenBar(context, title: 'Tools & permissions', showBack: true),
      body: ListView(padding: kPagePadding, children: [
        const DeviceAccessStatus(),
        // ── when tools are used ──
        const SectionHeader('How the AI decides'),
        Obx(() =>
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<AgentChatMode>(
                  segments: const [
                    ButtonSegment(
                        value: AgentChatMode.auto, label: Text('Auto')),
                    ButtonSegment(
                        value: AgentChatMode.always, label: Text('Always')),
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
                    'The model reads every request and decides whether to answer directly or use available tools. Tool use is never triggered by words in your message.',
                  AgentChatMode.always =>
                    'Offers more tool details to the model. The model still decides whether to use a tool; this does not make small models more reliable.',
                  AgentChatMode.off =>
                    'The AI only chats. No tools, no file access.',
                },
                style: t.caption,
              ),
            ])),

        Obx(() {
          final cloud =
              Get.find<SettingsController>().inferenceMode.value == 'cloud';
          final inference = Get.find<InferenceService>();
          final description = cloud
              ? (Get.find<CloudService>().supportsNativeTools
                  ? 'Native provider tool calls are validated before execution. Provider/model support is checked by the request; unsupported calls return an error.'
                  : 'This provider uses the validated structured-output adapter. Tool reliability depends on the selected model.')
              : !inference.isModelLoaded.value
                  ? 'Load a local model before using the assistant.'
                  : inference.supportsToolSchema.value
                      ? 'The loaded model template supports native tools. NeuroMesh passes function schemas through that template and validates parsed calls before execution. Small contexts discover additional schemas as needed.'
                      : 'This model does not advertise tool support. Structured tool output is unverified; malformed responses stop execution safely. Use Off for direct chat.';
          return Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(description, style: t.caption));
        }),

        if (SandboxService.supported) ...[
          const SectionHeader('Linux sandbox'),
          const _SandboxCard(),
        ],

        // ── schedule ──
        const SectionHeader('Scheduled tasks'),
        AppGroup(children: [
          AppRow(
            icon: Icons.schedule_rounded,
            title: 'Run tasks on a schedule',
            subtitle:
                'Daily news, reminders, reports: the AI does them by itself',
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
                subtitle:
                    'Say "remember that…" or let the AI save facts. Notes are added to every chat.',
                trailing: Switch(
                    value: _agent.autoMemory.value,
                    onChanged: _agent.setAutoMemory),
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
              decoration: appInputDecoration(context,
                  hint: 'Add a note the AI should remember'),
              onSubmitted: (_) => _addNote(),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filledTonal(
              onPressed: _addNote, icon: const Icon(Icons.add_rounded)),
        ]),
        Obx(() => _agent.memory.isEmpty
            ? const SizedBox.shrink()
            : Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                    onPressed: _agent.clearMemory,
                    child: const Text('Clear all memory')))),

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
                  subtitle: 'Available to the AI under your tool permissions',
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
                    showToast('Could not open the picker', '$e',
                        tone: ToastTone.error);
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
              if (hasDesktopShell)
                AppRow(
                  icon: Icons.terminal_rounded,
                  title: 'Desktop command access',
                  subtitle: 'Choose the computer or a VM and review approvals',
                  chevron: true,
                  onTap: () => Get.to(() => const DesktopAccessView()),
                ),
              for (final tool in _agent.catalog)
                if (!hasDesktopShell || tool.name != 'run_shell')
                  _PolicyRow(
                    title: tool.name,
                    subtitle: tool.description,
                    value: _agent.policyFor('built-in', tool.name,
                        needsConfirm: tool.needsConfirm),
                    onChanged: (v) =>
                        _agent.setPolicy('built-in', tool.name, v),
                  ),
            ])),
        Obx(() => _agent.policy.isEmpty
            ? const SizedBox.shrink()
            : Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                    onPressed: _agent.resetPolicies,
                    child: const Text('Reset tool approvals')))),

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
                  subtitle: _agent.serverStatus[s.id] ??
                      (s.enabled ? 'Not connected yet' : 'Off'),
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
        TextField(
            controller: ctl,
            minLines: 2,
            maxLines: 6,
            decoration: appInputDecoration(ctx)),
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
    await showAppSheet<void>(context, title: 'Ready-made servers',
        builder: (ctx) {
      return AppGroup(children: [
        for (final p in kMcpPresets)
          AppRow(
            icon: p.unsupported != null
                ? Icons.block_rounded
                : Icons.hub_outlined,
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
    await showAppSheet<void>(context, title: p.name, subtitle: p.blurb,
        builder: (ctx) {
      return StatefulBuilder(builder: (ctx, setS) {
        if (p.unsupported != null)
          return AppNotice(p.unsupported!, icon: Icons.info_outline_rounded);
        return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
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
                        final u = presetUrl(p, {
                          for (final e in fields.entries) e.key: e.value.text
                        });
                        setS(() {
                          busy = true;
                          error = null;
                        });
                        try {
                          await McpOAuth.signIn(u);
                          final cfg = McpServerConfig(
                              id: 'test', name: p.name, url: u, token: '');
                          final tools = await _agent.testServer(cfg);
                          await _agent.addServer(cfg.name, cfg.url, '');
                          if (ctx.mounted) Navigator.pop(ctx);
                          showToast(
                              'Connected', '${p.name}: ${tools.length} tools',
                              tone: ToastTone.success);
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
                    decoration:
                        appInputDecoration(ctx, label: f.label, hint: f.hint)),
              ],
              if (error != null) ...[
                const SizedBox(height: 8),
                AppNotice(error!,
                    icon: Icons.error_outline_rounded, color: Colors.red),
              ],
              const SizedBox(height: 14),
              PrimaryButton(
                label: 'Connect',
                busy: busy,
                onPressed: () async {
                  if (p.tokenLabel != null &&
                      token.text.trim().isEmpty &&
                      !await McpOAuth.hasTokens(presetUrl(p, {
                        for (final e in fields.entries) e.key: e.value.text
                      }))) {
                    setS(() => error =
                        'Paste a token, or use "Sign in with browser".');
                    return;
                  }
                  final cfg = McpServerConfig(
                    id: 'test',
                    name: p.name,
                    url: presetUrl(p,
                        {for (final e in fields.entries) e.key: e.value.text}),
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
                    showToast('Connected', '${p.name}: ${tools.length} tools',
                        tone: ToastTone.success);
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
    await showAppSheet<void>(context, title: 'Paste a config or URL',
        builder: (ctx) {
      return StatefulBuilder(builder: (ctx, setS) {
        return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: ctl,
                minLines: 5,
                maxLines: 10,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
                decoration: appInputDecoration(ctx,
                    hint:
                        '{"mcpServers":{"name":{"url":"https://…","headers":{"Authorization":"Bearer …"}}}}'),
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
                    await _agent.addServer(s.name, s.url, '',
                        headers: s.headers);
                  }
                  if (ctx.mounted) Navigator.pop(ctx);
                  showToast(
                      'Added ${r.servers.length}',
                      r.skipped.isEmpty
                          ? 'Connecting…'
                          : 'Skipped: ${r.skipped.join('; ')}',
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
            : existing.headers.entries
                .map((e) => '${e.key}: ${e.value}')
                .join('\n'));
    String? result;
    var ok = false;
    var busy = false;

    Map<String, String> parseHeaders() {
      final out = <String, String>{};
      for (final line in headers.text.split('\n')) {
        final i = line.indexOf(':');
        if (i > 0)
          out[line.substring(0, i).trim()] = line.substring(i + 1).trim();
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

    await showAppSheet<void>(context,
        title: existing == null ? 'Add a server' : existing.name,
        builder: (ctx) {
      return StatefulBuilder(builder: (ctx, setS) {
        return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                  controller: name,
                  decoration: appInputDecoration(ctx, label: 'Name')),
              const SizedBox(height: 8),
              TextField(
                  controller: url,
                  keyboardType: TextInputType.url,
                  decoration: appInputDecoration(ctx,
                      label: 'Server URL', hint: 'https://…/mcp')),
              const SizedBox(height: 8),
              TextField(
                  controller: token,
                  obscureText: true,
                  decoration: appInputDecoration(ctx,
                      label: 'Bearer token (optional)')),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  icon: const Icon(Icons.login_rounded, size: 18),
                  label: FutureBuilder<bool>(
                    future: McpOAuth.hasTokens(url.text.trim()),
                    builder: (_, snapshot) => Text(snapshot.data == true
                        ? 'Signed in · sign in again'
                        : 'Sign in with browser'),
                  ),
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
                            await McpOAuth.signIn(u,
                                onStatus: (m) => setS(() => result = m));
                            final tools = await _agent.testServer(build());
                            setS(() {
                              ok = true;
                              result =
                                  'Signed in. ${tools.length} tools available.';
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
                      label: 'Other headers (optional)',
                      hint: 'Header-Name: value, one per line')),
              if (result != null) ...[
                const SizedBox(height: 8),
                AppNotice(result!,
                    icon: ok
                        ? Icons.check_circle_outline_rounded
                        : Icons.error_outline_rounded,
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
                                result =
                                    'Works: ${tools.length} tools (${tools.take(4).map((e) => e.name).join(', ')}${tools.length > 4 ? '…' : ''})';
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
                        await _agent.addServer(cfg.name, cfg.url, cfg.token,
                            headers: cfg.headers);
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
                  if (_agent.toolsVersion.value < 0)
                    return const SizedBox
                        .shrink(); // rebuilds when tools change
                  final tools = _agent.toolsOf(existing.id);
                  final s = _agent.servers
                          .firstWhereOrNull((x) => x.id == existing.id) ??
                      existing;
                  return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        AppRow(
                          icon: Icons.power_settings_new_rounded,
                          title: 'Enabled',
                          trailing: Switch(
                              value: s.enabled,
                              onChanged: (v) =>
                                  _agent.setEnabled(existing.id, v)),
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
                                    : _agent.policyFor(s.name, tl.name,
                                        needsConfirm: true),
                                onChanged: (v) async {
                                  if (v == 'block') {
                                    await _agent.setToolEnabled(
                                        existing.id, tl.name, false);
                                  } else {
                                    await _agent.setToolEnabled(
                                        existing.id, tl.name, true);
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
                          child: const Text('Remove this server',
                              style: TextStyle(color: Colors.red)),
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
      subtitle:
          subtitle.length > 90 ? '${subtitle.substring(0, 90)}…' : subtitle,
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
                style: TextStyle(
                    color: color, fontWeight: FontWeight.w600, fontSize: 13)),
            Icon(Icons.arrow_drop_down_rounded, color: color),
          ]),
        ),
      ),
    );
  }
}

class AgentWorkspaceView extends StatelessWidget {
  const AgentWorkspaceView({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: appScreenBar(context, title: 'Agent workspace', showBack: true),
        body: ListView(padding: kPagePadding, children: [
          _Workspace(agent: Get.find<AgentService>()),
          if (SandboxService.supported)
            AppGroup(children: [
              AppRow(
                icon: Icons.terminal_rounded,
                title: 'Alpine terminal',
                chevron: true,
                onTap: () => Get.to(() => const AlpineTerminalView()),
              ),
            ]),
        ]),
      );
}

class AlpineTerminalView extends StatefulWidget {
  const AlpineTerminalView({super.key});

  @override
  State<AlpineTerminalView> createState() => AlpineTerminalViewState();
}

class AlpineTerminalViewState extends State<AlpineTerminalView> {
  final _sandbox = Get.find<SandboxService>();
  final _input = TextEditingController();
  final _output = ScrollController();
  final _entries = <String>[];
  late final _agent = Get.find<AgentService>();
  late final _project =
      _agent.projectForChat(Get.find<ChatController>().currentSessionId.value);
  bool _running = false;
  String _cwd = '/workspace';

  @override
  void dispose() {
    _input.dispose();
    _output.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final command = _input.text.trim();
    if (_running || command.isEmpty || !_sandbox.installed.value) return;
    setState(() {
      _running = true;
      _entries.add('\$ $command');
      _input.clear();
    });
    try {
      const marker = '__neuromesh_working_directory__=';
      final script = """trap 'printf "\n$marker%s\n" "\$(pwd -P)"' EXIT
$command""";
      final result = await _agent.inProject(
          _project, () => _sandbox.run(script, workingDirectory: _cwd));
      final lines = result.split('\n');
      final finalDirectory =
          lines.lastIndexWhere((line) => line.startsWith(marker));
      if (mounted)
        setState(() {
          if (finalDirectory >= 0) {
            final path =
                lines.removeAt(finalDirectory).substring(marker.length);
            if (path.startsWith('/')) _cwd = path;
          }
          _entries.add(lines.join('\n').trim());
        });
    } finally {
      if (mounted) {
        setState(() => _running = false);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _output.hasClients) {
            _output.jumpTo(_output.position.maxScrollExtent);
          }
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: appScreenBar(context, title: 'Alpine terminal', showBack: true),
        body: SafeArea(child: Obx(() {
          if (!_sandbox.installed.value) {
            return Center(
              child: FilledButton(
                onPressed: _sandbox.busy.value
                    ? null
                    : () async {
                        try {
                          await _sandbox.install();
                        } catch (error) {
                          if (context.mounted)
                            showToast('Install failed', '$error');
                        }
                      },
                child: Text(_sandbox.busy.value
                    ? _sandbox.status.value
                    : 'Install Alpine Linux'),
              ),
            );
          }
          return Column(children: [
            ListTile(
              title: Text(_cwd),
              subtitle: const Text(
                  '/workspace contains the files shared with this chat’s agent.'),
            ),
            Expanded(
              child: ListView.builder(
                controller: _output,
                padding: const EdgeInsets.all(16),
                itemCount: _entries.length,
                itemBuilder: (_, index) => SelectableText(
                  _entries[index],
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              ),
            ),
            if (_running) const LinearProgressIndicator(),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    decoration: const InputDecoration(labelText: 'Command'),
                    autocorrect: false,
                    onSubmitted: (_) => _run(),
                  ),
                ),
                IconButton(
                  tooltip: 'Run command',
                  onPressed: _running ? null : _run,
                  icon: const Icon(Icons.play_arrow_rounded),
                ),
              ]),
            ),
          ]);
        })),
      );
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
          out.add(
              FileSystemEntityInfo(f.path, f.uri.pathSegments.last, st.size));
        }
        out.sort((a, b) => a.name.compareTo(b.name));
        final archived = await widget.agent.archivedWorkspaceFiles();
        return (
          out,
          archived
              .where((name) => !out.any((item) => item.name == name))
              .toList()
        );
      });
      if (mounted && _project == project)
        setState(() {
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
          TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(dialog, ''),
              child: const Text('Use shared workspace')),
          FilledButton(
              onPressed: () => Navigator.pop(dialog, name.trim()),
              child: const Text('Save')),
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
    final versions = await widget.agent
        .inProject(project, () => widget.agent.workspaceVersions(name));
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
                  title: Text(DateTime.fromMicrosecondsSinceEpoch(version)
                      .toLocal()
                      .toString()
                      .split('.')
                      .first),
                  trailing: const Icon(Icons.restore_rounded),
                  onTap: () => Navigator.pop(context, version),
                ),
            ]),
    );
    if (selected == null || !mounted) return;
    try {
      final restored = await widget.agent.inProject(
          project, () => widget.agent.restoreWorkspaceVersion(name, selected));
      if (mounted)
        showToast(restored ? 'File restored' : 'Version unavailable', name);
      await _load();
    } catch (_) {
      if (mounted)
        showToast('Could not restore the file', name, tone: ToastTone.error);
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
          onTap: () => widget.agent.inProject(_project,
              () => openAgentFile(context, Uri.encodeComponent(f.name))),
          subtitle:
              '${(f.size / 1024).toStringAsFixed(f.size < 10240 ? 1 : 0)} KB · AI workspace',
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
                await widget.agent.inProject(
                    _project, () => widget.agent.deleteWorkspaceFile(f.name));
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
          await widget.agent.inProject(
              _project, () => widget.agent.importToWorkspace(f!.path!, f.name));
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
            title:
                sb.installed.value ? 'Alpine terminal' : 'Install Alpine Linux',
            onTap: sb.installed.value
                ? () => Get.to(() => const AlpineTerminalView())
                : null,
            subtitle: sb.busy.value
                ? sb.status.value
                : sb.installed.value
                    ? 'The AI can run commands, create files and deploy from here'
                    : 'About 4 MB download. Lets the AI run real commands (python, node, git, curl…).',
            trailing: sb.busy.value
                ? SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        value: sb.downloadProgress.value, strokeWidth: 2))
                : sb.installed.value
                    ? IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          try {
                            await sb.uninstall();
                          } catch (error) {
                            Get.snackbar('Linux is busy', '$error');
                          }
                        })
                    : IconButton(
                        icon: const Icon(Icons.download_rounded),
                        onPressed: () async {
                          try {
                            await sb.install();
                          } catch (e) {
                            Get.snackbar('Install failed',
                                '$e'.replaceFirst('Exception: ', ''));
                          }
                        }),
          ),
        ]));
  }
}
