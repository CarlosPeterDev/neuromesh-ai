import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../services/hive_service.dart';
import 'setup_view.dart';
import 'model_quiz_view.dart';

const _kOnboarded = 'onboarding_seen';
const _kWhatsNew = 'whats_new_version';

const _news = <String>[
  'Voice and video calls now start from the chat composer.',
  'Video calls show the camera full-screen.',
  'Select Think or Direct answer with compatible local models.',
  'Find a model matches a starter download to your needs and device.',
];

/// Onboarding on first run, "what's new" after updates, then the model picker.
Future<void> runFirstRunFlow(BuildContext context) async {
  final hive = Get.find<HiveService>();
  if (hive.getSetting<bool>(_kOnboarded) != true) {
    if (context.mounted) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(builder: (_) => const ModelQuizView(welcome: true)),
      );
      await hive.setSetting(_kOnboarded, true);
      await hive.setSetting(kSetupDone, true);
    }
  } else {
    final info = await PackageInfo.fromPlatform();
    final seen = hive.getSetting<String>(_kWhatsNew);
    if (seen != info.version) {
      await hive.setSetting(_kWhatsNew, info.version);
      if (seen != null && context.mounted)
        await _showWhatsNew(context, info.version);
    }
  }
  try {
    final info = await PackageInfo.fromPlatform();
    await hive.setSetting(_kWhatsNew, info.version);
  } catch (_) {}
  if (context.mounted) await maybeShowSetup();
}

Future<void> _showWhatsNew(BuildContext context, String version) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text("What's new in $version"),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final n in _news)
            Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Text('• $n'))
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))
      ],
    ),
  );
}
