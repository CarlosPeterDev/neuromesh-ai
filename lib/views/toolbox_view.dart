import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/chat_controller.dart';
import '../core/ui.dart';
import '../services/device_bridge.dart';
import '../services/diagnostics_service.dart';
import 'diagnostics_view.dart';
import '../services/toolbox_service.dart';
import '../services/voice_service.dart';
import 'storage_view.dart';
import 'perf_views.dart';
import '../services/rag_service.dart';
import '../services/web_search_service.dart';
import '../services/hive_service.dart';
import '../services/download_queue.dart';
import 'voice_views.dart';
import 'chat_tools.dart';
import '../services/sandbox_service.dart';
import 'voice_clone_view.dart';

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
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: t.bg,
        appBar: appScreenBar(context, title: 'Toolbox'),
        body: Column(children: [
          const TabBar(tabs: [
            Tab(text: 'AI tools'),
            Tab(text: 'Models'),
            Tab(text: 'Data & support'),
          ]),
          Expanded(child: TabBarView(children: [
            ListView(padding: kPagePadding, children: _aiTools(context)),
            ListView(padding: kPagePadding, children: _modelTools(context)),
            ListView(padding: kPagePadding, children: _supportTools(context)),
          ])),
        ]),
      ),
    );
  }

  List<Widget> _aiTools(BuildContext context) => [
        Obx(() {
          final adv = Get.find<DeviceBridge>().advisory;
          if (adv == null) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: AppGroup(children: [
              AppRow(icon: Icons.thermostat_rounded, title: 'Heads up', subtitle: adv),
            ]),
          );
        }),
        if (SandboxService.supported)
          AppGroup(children: [
            AppRow(
              icon: Icons.terminal_rounded,
              title: 'Alpine terminal',
              chevron: true,
              onTap: () => Get.to(() => const AlpineTerminalView()),
            ),
          ]),
        const SectionHeader('Voice'),
        AppGroup(dividerIndent: 60, children: [
          AppRow(
            icon: Icons.call_rounded,
            title: 'Start a voice call',
            subtitle: 'Talk to your local model hands-free',
            chevron: true,
            onTap: () => Get.to(() => const VoiceCallView()),
          ),
          AppRow(
            icon: Icons.download_for_offline_outlined,
            title: 'Voice models',
            subtitle: 'Download listening and speaking models',
            chevron: true,
            onTap: () => Get.to(() => const VoiceModelsView()),
          ),
          AppRow(
            icon: Icons.mic_external_on_rounded,
            title: 'Voice cloning',
            subtitle: 'Speak in your own voice; optional worker phone',
            chevron: true,
            onTap: () => Get.to(() => const VoiceCloneView()),
          ),
          AppRow(
            icon: Icons.volume_up_rounded,
            title: 'Read last reply aloud',
            onTap: () {
              final msgs = Get.find<ChatController>().messages;
              final reversed = msgs.reversed.where((m) => m.role == 'assistant');
              final last = reversed.isEmpty ? null : reversed.first;
              if (last == null) {
                _toast('No reply to read yet.');
                return;
              }
              final ar = RegExp(r'[\u0600-\u06FF]').hasMatch(last.content);
              Get.find<VoiceService>()
                  .speak(last.content, systemLang: ar ? 'ar' : 'en-US');
            },
          ),
        ]),
        const SectionHeader('Web search'),
        Obx(() {
          final w = Get.find<WebSearchService>();
          String label(WebSearchMode m) => switch (m) {
                WebSearchMode.off => 'Off',
                WebSearchMode.auto => 'Auto',
                WebSearchMode.always => 'Always',
              };
          return AppGroup(dividerIndent: 60, children: [
            AppRow(
              icon: Icons.travel_explore_rounded,
              title: 'Search the web for answers',
              subtitle: switch (w.mode.value) {
                WebSearchMode.off => 'Off. Nothing leaves your phone.',
                WebSearchMode.auto =>
                  'Searches when a question needs fresh info (news, prices, weather, "latest").',
                WebSearchMode.always => 'Searches for every message.',
              },
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: SegmentedButton<WebSearchMode>(
                segments: [
                  for (final m in WebSearchMode.values)
                    ButtonSegment(value: m, label: Text(label(m)))
                ],
                selected: {w.mode.value},
                onSelectionChanged: (s) => w.setMode(s.first),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                  'Your question is sent to DuckDuckGo (or Wikipedia as a backup), and the top pages are read. Free, no account. Answers list their sources.',
                  style: TextStyle(fontSize: 12)),
            ),
          ]);
        }),
        const SectionHeader('Chat with documents'),
        Obx(() {
          final rag = Get.find<RagService>();
          return AppGroup(dividerIndent: 60, children: [
            AppRow(
              icon: Icons.menu_book_outlined,
              title: 'Use my documents in chats',
              subtitle: 'Adds the best-matching passages to your question. Keyword search, fully offline.',
              trailing: Switch(value: rag.enabled.value, onChanged: rag.setEnabled),
            ),
            for (final d in rag.docs)
              AppRow(
                icon: Icons.description_outlined,
                title: d.name,
                subtitle: '${d.chunks} passages',
                trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, size: 20),
                    onPressed: () => rag.remove(d)),
              ),
            AppRow(
              icon: rag.busy.value ? Icons.hourglass_top_rounded : Icons.add_rounded,
              title: rag.busy.value ? 'Reading document…' : 'Add document (PDF, DOCX, TXT…)',
              onTap: rag.busy.value ? null : () async => _toast(await rag.addDocument()),
            ),
          ]);
        }),
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
      ];

  List<Widget> _modelTools(BuildContext context) => [
        const SectionHeader('Performance & downloads'),
        AppGroup(dividerIndent: 60, children: [
          AppRow(
            icon: Icons.speed_rounded,
            title: 'Benchmark loaded model',
            subtitle: 'Measures first-token time and tokens per second',
            onTap: () async {
              _toast('Running benchmark…');
              final r = await runBenchmark();
              if (!context.mounted) return;
              showDialog<void>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                        title: const Text('Benchmark'),
                        content: Text(r),
                        actions: [
                          TextButton(
                              onPressed: () => Navigator.pop(ctx),
                              child: const Text('OK'))
                        ],
                      ));
            },
          ),
          AppRow(
            icon: Icons.compare_rounded,
            title: 'Compare two models',
            subtitle: 'Same prompt, side-by-side answers',
            chevron: true,
            onTap: () => Get.to(() => const CompareView()),
          ),
          _SwitchRow(
              icon: Icons.memory_rounded,
              title: 'Auto context size',
              subtitle: 'Lowers the context if the model would not fit in RAM',
              keyName: 'auto_context',
              defaultValue: true),
          _SwitchRow(
              icon: Icons.play_circle_outline_rounded,
              title: 'Load last model on start',
              subtitle: 'Opens ready to chat. Uses RAM right away.',
              keyName: 'auto_load_last',
              defaultValue: false),
          _SwitchRow(
              icon: Icons.title_rounded,
              title: 'Auto-title chats',
              subtitle: 'Uses the loaded model to name new chats',
              keyName: 'auto_title',
              defaultValue: true),
          _SwitchRow(
              icon: Icons.wifi_rounded,
              title: 'Download on Wi-Fi only',
              subtitle: 'Applies to new in-app downloads',
              keyName: 'wifi_only',
              defaultValue: false),
          Obx(() {
            final q = Get.find<DownloadQueue>();
            final cur = q.current.value;
            return Column(children: [
              AppRow(
                icon: Icons.queue_rounded,
                title: 'Download queue',
                subtitle: cur == null && q.queue.isEmpty
                    ? 'Empty. Add models from Hugging Face.'
                    : '${q.queue.length} waiting',
                trailing: cur == null && q.queue.isEmpty
                    ? null
                    : TextButton(
                        onPressed: q.cancelAll, child: const Text('Cancel all')),
              ),
              if (cur != null)
                AppRow(
                  icon: Icons.downloading_rounded,
                  title: cur.name,
                  subtitle: 'Downloading now',
                  trailing: IconButton(
                      tooltip: 'Cancel this download',
                      icon: const Icon(Icons.close_rounded),
                      onPressed: q.cancelCurrent),
                ),
              for (final m in q.queue)
                AppRow(
                  icon: Icons.schedule_rounded,
                  title: m.name,
                  subtitle: 'Waiting',
                  trailing: IconButton(
                      tooltip: 'Remove from queue',
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => q.remove(m)),
                ),
            ]);
          }),
        ]),
      ];

  List<Widget> _supportTools(BuildContext context) => [
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
        const SectionHeader('Device & support'),
        AppGroup(dividerIndent: 60, children: [
          Obx(() {
            final d = Get.find<DeviceBridge>();
            return AppRow(
              icon: Icons.battery_charging_full_rounded,
              title: 'Battery & temperature',
              subtitle:
                  'Battery ${d.batteryLevel.value}%${d.charging.value ? ' (charging)' : ''} · thermal level ${d.thermal.value}',
              onTap: d.refresh,
            );
          }),
          AppRow(
            icon: Icons.sd_storage_outlined,
            title: 'Storage manager',
            subtitle: 'See and delete downloaded models',
            chevron: true,
            onTap: () => Get.to(() => const StorageView()),
          ),
          AppRow(
            icon: Icons.bug_report_outlined,
            title: 'Report an error',
            subtitle: 'Review and send diagnostics to support.',
            chevron: true,
            onTap: () => Get.to(() => const DiagnosticsView()),
          ),
          AppRow(
            icon: Icons.feedback_outlined,
            title: 'Send feedback',
            subtitle: 'Opens a draft for the public GitHub issue tracker.',
            onTap: () async {
              final text = await _ask(context, 'What happened?', 'Describe the problem or idea', lines: 4);
              if (text == null || text.isEmpty) return;
              try {
                final ok = await DiagnosticsService.openIssueDraft(text);
                if (!ok) _toast('Could not open the browser.');
              } catch (_) {
                _toast('Could not open the browser.');
              }
            },
          ),
        ]),
      ];

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


class _SwitchRow extends StatefulWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String keyName;
  final bool defaultValue;
  const _SwitchRow(
      {required this.icon,
      required this.title,
      required this.subtitle,
      required this.keyName,
      required this.defaultValue});

  @override
  State<_SwitchRow> createState() => _SwitchRowState();
}

class _SwitchRowState extends State<_SwitchRow> {
  late bool _v = Get.find<HiveService>()
          .getSetting<bool>(widget.keyName, defaultValue: widget.defaultValue) ??
      widget.defaultValue;

  @override
  Widget build(BuildContext context) => AppRow(
        icon: widget.icon,
        title: widget.title,
        subtitle: widget.subtitle,
        trailing: Switch(
            value: _v,
            onChanged: (v) {
              setState(() => _v = v);
              Get.find<HiveService>().setSetting(widget.keyName, v);
            }),
      );
}
