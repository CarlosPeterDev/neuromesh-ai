import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/ui.dart';
import '../services/agent_adapter.dart';
import '../services/inference_service.dart';
import '../services/opencode_adapter.dart';

bool agentHubUsesArabic(BuildContext context) =>
    View.of(context).platformDispatcher.locale.languageCode == 'ar';

class AgentHubView extends StatefulWidget {
  const AgentHubView({super.key});

  @override
  State<AgentHubView> createState() => _AgentHubViewState();
}

class _AgentHubViewState extends State<AgentHubView> {
  final _adapter = createOpenCodeAdapter();
  final _inference = Get.find<InferenceService>();
  AgentInstallation? _installation;
  AgentTerminalSession? _session;
  bool _busy = false;
  bool _failed = false;

  Future<void> _act(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _launch() async {
    final session = await _adapter.openTerminal(
      installation: _installation!,
      modelName: _inference.loadedModelName.value,
      contextTokens: _inference.contextTokensTotal.value,
    );
    unawaited(_watch(session));
    if (mounted) {
      setState(() => _session = session);
    } else {
      await session.disconnect();
    }
  }

  Future<void> _watch(AgentTerminalSession session) async {
    var failed = false;
    try {
      failed = await session.exitCode != 0;
    } catch (_) {
      failed = true;
    }
    if (!mounted || _session != session) return;
    setState(() {
      _session = null;
      _failed = failed;
    });
  }

  @override
  void dispose() {
    final session = _session;
    if (session != null) unawaited(session.disconnect());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final arabic = agentHubUsesArabic(context);
    String tr(String english, String arabicText) =>
        arabic ? arabicText : english;
    final installation = _installation;
    final executable = installation?.executable;
    final version = installation?.version;
    final status = installation == null
        ? tr('Check for an existing installation.', 'تحقق من وجود تثبيت حالي.')
        : executable == null
            ? tr('OpenCode was not found.', 'لم يتم العثور على OpenCode.')
            : version == null
                ? tr('The executable did not report a version.',
                    'لم يعرض الملف التنفيذي رقم الإصدار.')
                : tr('Installed version $version', 'الإصدار المثبّت $version');
    final terminalStatus = installation?.compatible == true
        ? installation?.terminalAvailable == true
            ? tr('System terminal available.', 'طرفية النظام متاحة.')
            : tr(
                'Open a Linux desktop session with Xfce Terminal or xterm installed.',
                'افتح جلسة سطح مكتب لينكس مع طرفية Xfce أو xterm.')
        : tr(
            'The local bridge supports OpenCode 1.19.6 on Linux with a supported terminal.',
            'يدعم الجسر المحلي OpenCode 1.19.6 على لينكس مع طرفية مدعومة.');

    return Directionality(
      textDirection: arabic ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        appBar: appScreenBar(context, title: tr('Agent Hub', 'مركز الوكلاء')),
        body: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              shrinkWrap: true,
              padding: kPagePadding,
              children: [
                AppGroup(children: [
                  AppRow(
                    icon: Icons.code_rounded,
                    title: _adapter.name,
                    subtitle: status,
                  ),
                ]),
                if (executable != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: SelectableText(executable,
                        textDirection: TextDirection.ltr),
                  ),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  OutlinedButton(
                    onPressed: _busy || _session != null
                        ? null
                        : () => _act(() async {
                              final detected = await _adapter.discover();
                              if (mounted) {
                                setState(() => _installation = detected);
                              }
                            }),
                    child: Text(tr('Check installation', 'التحقق من التثبيت')),
                  ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => _act(() async {
                              if (!await launchUrl(_adapter.installationGuide,
                                  mode: LaunchMode.externalApplication)) {
                                throw StateError(
                                    'Unable to open installation guide.');
                              }
                            }),
                    child: Text(tr(
                        'Official installation guide', 'دليل التثبيت الرسمي')),
                  ),
                ]),
                const SizedBox(height: 16),
                Text(terminalStatus),
                const SizedBox(height: 8),
                Text(tr(
                  'Terminal opens a temporary OpenCode session with the loaded model. The bridge uses this device only and needs no provider account. This preview supports text replies. Coding tools, project access and in-app OpenCode Chat are unavailable.',
                  'تفتح الطرفية جلسة OpenCode مؤقتة مع النموذج المحمّل. يعمل الجسر على هذا الجهاز فقط ولا يتطلب حساب مزوّد. تدعم هذه المعاينة الردود النصية فقط. أدوات البرمجة والوصول إلى المشاريع ودردشة OpenCode داخل التطبيق غير متاحة.',
                )),
                const SizedBox(height: 12),
                Obx(() {
                  final model = _inference.loadedModelName.value;
                  final ready = _inference.isModelLoaded.value &&
                      _inference.contextTokensTotal.value >= 1024;
                  return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (_session == null) ...[
                          Text(ready
                              ? tr('Model to connect · $model',
                                  'النموذج المراد ربطه · $model')
                              : tr(
                                  'Load a local model with at least 1024 context tokens in Models.',
                                  'حمّل نموذجاً محلياً بسياق لا يقل عن 1024 رمزاً من صفحة النماذج.')),
                          const SizedBox(height: 8),
                          FilledButton.icon(
                            onPressed: !_busy &&
                                    ready &&
                                    installation?.compatible == true &&
                                    installation?.terminalAvailable == true
                                ? () => _act(_launch)
                                : null,
                            icon: const Icon(Icons.terminal_rounded),
                            label: Text(tr('Connect model and open Terminal',
                                'ربط النموذج وفتح الطرفية')),
                          ),
                        ] else ...[
                          Text(tr('OpenCode Terminal is connected.',
                              'طرفية OpenCode متصلة.')),
                          const SizedBox(height: 8),
                          OutlinedButton(
                            onPressed: _busy
                                ? null
                                : () => _act(() async {
                                      final session = _session!;
                                      await session.disconnect();
                                      if (mounted) {
                                        setState(() => _session = null);
                                      }
                                    }),
                            child: Text(
                                tr('Disconnect model', 'قطع اتصال النموذج')),
                          ),
                        ],
                      ]);
                }),
                if (_busy) const LinearProgressIndicator(),
                if (_failed)
                  Text(
                    tr('The action failed. Check OpenCode and the terminal, then try again.',
                        'تعذّر إكمال الإجراء. تحقق من OpenCode والطرفية ثم حاول مجدداً.'),
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
