import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../core/ui.dart';
import '../services/voice_worker.dart';
import '../services/workload_placement.dart';

class WorkloadPlacementView extends StatefulWidget {
  const WorkloadPlacementView({super.key});

  @override
  State<WorkloadPlacementView> createState() => _WorkloadPlacementViewState();
}

class _WorkloadPlacementViewState extends State<WorkloadPlacementView> {
  final _server = Get.find<VoiceWorkerServer>();
  bool _starting = false;

  Future<void> _configure(PhoneWorkload job) async {
    final current = WorkloadPlacement.forWorkload(job);
    var address = current?.address.toString() ?? '';
    var token = current?.token ?? '';
    var busy = false;
    String? error;
    await showAppSheet<void>(
      context,
      title: job.label,
      subtitle: 'Use the address and access code shown on the worker phone.',
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheet) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              initialValue: address,
              enabled: !busy,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(labelText: 'Worker address'),
              onChanged: (value) => address = value,
            ),
            TextFormField(
              initialValue: token,
              enabled: !busy,
              obscureText: true,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Access code'),
              onChanged: (value) => token = value,
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      final worker = WorkloadWorker.parse(address, token);
                      if (worker == null) {
                        setSheet(() => error =
                            'Enter a private Wi-Fi address and its access code.');
                        return;
                      }
                      setSheet(() {
                        busy = true;
                        error = null;
                      });
                      try {
                        final ready = await worker.capabilities();
                        if (!ready.contains(job.name)) {
                          throw StateError(
                              'Install and prepare the ${job.label.toLowerCase()} model on that phone.');
                        }
                        if (!sheetContext.mounted) return;
                        await WorkloadPlacement.assign(job, worker);
                        if (sheetContext.mounted) Navigator.pop(sheetContext);
                      } catch (e) {
                        if (context.mounted) {
                          setSheet(() {
                            busy = false;
                            error = 'Could not assign worker. $e';
                          });
                        }
                      }
                    },
              child: Text(busy ? 'Checking worker…' : 'Assign worker'),
            ),
            if (current != null)
              TextButton(
                onPressed: busy
                    ? null
                    : () async {
                        await WorkloadPlacement.assign(job, null);
                        if (sheetContext.mounted) Navigator.pop(sheetContext);
                      },
                child: const Text('Use this phone'),
              ),
          ],
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _toggleServer() async {
    setState(() => _starting = true);
    try {
      if (_server.running.value) {
        await _server.stop();
      } else {
        await _server.start();
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _copy(String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Copied to clipboard')));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar:
            appScreenBar(context, title: 'Workload placement', showBack: true),
        body: ListView(
          padding: kPagePadding,
          children: [
            const SectionHeader('Choose a phone for each workload'),
            AppGroup(children: [
              for (final job in PhoneWorkload.values.where((item) => item != PhoneWorkload.image))
                AppRow(
                  icon: switch (job) {
                    PhoneWorkload.speech => Icons.volume_up_outlined,
                    PhoneWorkload.transcription => Icons.mic_none_rounded,
                    PhoneWorkload.image => Icons.image_outlined,
                  },
                  title: job.label,
                  subtitle:
                      WorkloadPlacement.forWorkload(job)?.address.authority ??
                          'This phone',
                  chevron: true,
                  onTap: () => _configure(job),
                ),
            ]),
            const SectionHeader('Use this phone as a worker'),
            const AppNotice(
              'Use a trusted Wi-Fi network. Assigned phones receive audio or text prompts for the workload you select.',
              icon: Icons.wifi_rounded,
            ),
            const SizedBox(height: 12),
            Obx(() {
              final running = _server.running.value;
              final error = _server.lastError.value;
              return AppGroup(children: [
                AppRow(
                  icon: Icons.hub_outlined,
                  title: running ? 'Stop worker' : 'Start worker',
                  subtitle: running
                      ? 'Keep NeuroMesh AI open on this phone.'
                      : 'Install voice models first.',
                  onTap: _starting ? null : _toggleServer,
                ),
                if (running) ...[
                  AppRow(
                    icon: Icons.lan_outlined,
                    title: 'Worker address',
                    subtitle: _server.address.value,
                    onTap: () => _copy(_server.address.value),
                  ),
                  AppRow(
                    icon: Icons.key_outlined,
                    title: 'Copy access code',
                    onTap: () => _copy(_server.token.value),
                  ),
                ],
                if (error.isNotEmpty)
                  AppRow(
                      icon: Icons.error_outline_rounded,
                      title: 'Worker error',
                      subtitle: error),
              ]);
            }),
          ],
        ),
      );
}
