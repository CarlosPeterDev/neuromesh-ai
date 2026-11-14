import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/model_controller.dart';
import '../models/ai_model.dart';
import '../services/device_info_service.dart';
import '../services/hive_service.dart';

const _kSeen = 'quick_start_seen';

AiModel _m(String name, String repo, String file, String size) => AiModel(
      name: name,
      filename: file,
      url: 'https://huggingface.co/$repo/resolve/main/$file',
      size: size,
      description: 'Hugging Face · $repo',
      template: 'chatml',
    );

/// Models that fit the phone's RAM, smallest first.
List<AiModel> quickStartModels(double ramGb) {
  final all = [
    _m('Qwen 2.5 0.5B (tiny, fast)', 'Qwen/Qwen2.5-0.5B-Instruct-GGUF',
        'qwen2.5-0.5b-instruct-q4_k_m.gguf', '491 MB'),
    _m('Qwen 2.5 1.5B (balanced)', 'Qwen/Qwen2.5-1.5B-Instruct-GGUF',
        'qwen2.5-1.5b-instruct-q4_k_m.gguf', '1.1 GB'),
    _m('Llama 3.2 3B (smarter)', 'bartowski/Llama-3.2-3B-Instruct-GGUF',
        'Llama-3.2-3B-Instruct-Q4_K_M.gguf', '2.0 GB'),
  ];
  if (ramGb < 4) return all.sublist(0, 1);
  if (ramGb < 7) return all.sublist(0, 2);
  return all;
}

/// Shows once, only when no model is downloaded yet.
Future<void> maybeShowQuickStart(BuildContext context) async {
  final hive = Get.find<HiveService>();
  if (hive.getSetting<bool>(_kSeen) == true) return;
  final mc = Get.find<ModelController>();
  if (mc.downloadedFiles.isNotEmpty) {
    await hive.setSetting(_kSeen, true);
    return;
  }
  final ram = Get.find<DeviceInfoService>().totalRamGB.value;
  await hive.setSetting(_kSeen, true);
  if (!context.mounted) return;
  final models = quickStartModels(ram);
  await showModalBottomSheet(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Pick a first model',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(
              'Your phone has about ${ram.toStringAsFixed(1)} GB of RAM. These models fit.',
              textAlign: TextAlign.center),
          const SizedBox(height: 12),
          for (final m in models)
            ListTile(
              title: Text(m.name),
              subtitle: Text(m.size),
              trailing: const Icon(Icons.download_rounded),
              onTap: () {
                Navigator.pop(ctx);
                mc.downloadModel(m);
                Get.snackbar('Downloading', m.name,
                    snackPosition: SnackPosition.BOTTOM);
              },
            ),
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Not now')),
        ]),
      ),
    ),
  );
}
