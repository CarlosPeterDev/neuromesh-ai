import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/chat_controller.dart';
import '../core/ui.dart';
import '../services/device_bridge.dart';
import '../services/diagnostics_service.dart';
import '../services/toolbox_service.dart';
import '../services/voice_service.dart';
import 'storage_view.dart';
import 'perf_views.dart';
import '../services/hive_service.dart';
import '../services/download_queue.dart';
import 'voice_views.dart';

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
            return AppRow(
              icon: Icons.queue_rounded,
              title: 'Download queue',
              subtitle: cur == null && q.queue.isEmpty
                  ? 'Empty. Add models from Hugging Face.'
                  : '${cur == null ? '' : 'Now: ${cur.name}. '}${q.queue.length} waiting',
            );
          }),
        ]),
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
            title: 'Export diagnostics',
            subtitle: 'Version, device and recent log. Secrets are removed.',
            onTap: () => DiagnosticsService.shareReport(),
          ),
          AppRow(
            icon: Icons.feedback_outlined,
            title: 'Send feedback',
            subtitle: 'Prepares a GitHub issue draft. No account needed to write it.',
            onTap: () async {
              final text = await _ask(context, 'What happened?', 'Describe the problem or idea', lines: 4);
              if (text == null || text.isEmpty) return;
              final ok = await DiagnosticsService.openIssueDraft(text);
              if (!ok) _toast('Could not open the browser.');
            },
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
