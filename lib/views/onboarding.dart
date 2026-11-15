import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../services/hive_service.dart';
import 'quick_start.dart';

const _kOnboarded = 'onboarding_seen';
const _kWhatsNew = 'whats_new_version';

const _pages = <({IconData icon, String title, String body})>[
  (
    icon: Icons.lock_outline_rounded,
    title: 'Private by design',
    body: 'Models run on your phone. Your chats stay on this device.'
  ),
  (
    icon: Icons.download_for_offline_outlined,
    title: 'Get a model',
    body: 'Open the Models tab and search Hugging Face, or let the quick-start picker choose one that fits your phone.'
  ),
  (
    icon: Icons.call_rounded,
    title: 'Talk to it',
    body: 'Download voice models in Toolbox, then tap the phone icon in any chat to start a hands-free call. Arabic and English are supported.'
  ),
  (
    icon: Icons.handyman_outlined,
    title: 'Your Toolbox',
    body: 'Settings → Toolbox has roles, saved prompts, document chat, compare, benchmark, backup and more.'
  ),
];

const _news = <String>[
  'Voice calls with on-device listening and speaking',
  'Pin chats, regenerate and edit-and-resend messages',
  'Chat with your documents (offline keyword search)',
  'Agent memory, private files and web fetch with approval',
  'Compare two models, benchmark, auto context size, download queue',
];

/// Onboarding on first run, "what's new" after updates, then the model picker.
Future<void> runFirstRunFlow(BuildContext context) async {
  final hive = Get.find<HiveService>();
  if (hive.getSetting<bool>(_kOnboarded) != true) {
    await hive.setSetting(_kOnboarded, true);
    if (context.mounted) await _showTour(context);
  } else {
    final info = await PackageInfo.fromPlatform();
    final seen = hive.getSetting<String>(_kWhatsNew);
    if (seen != info.version) {
      await hive.setSetting(_kWhatsNew, info.version);
      if (seen != null && context.mounted) await _showWhatsNew(context, info.version);
    }
  }
  try {
    final info = await PackageInfo.fromPlatform();
    await hive.setSetting(_kWhatsNew, info.version);
  } catch (_) {}
  if (context.mounted) await maybeShowQuickStart(context);
}

Future<void> _showTour(BuildContext context) {
  final ctl = PageController();
  var page = 0;
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => AlertDialog(
        content: SizedBox(
          width: 320,
          height: 260,
          child: Column(children: [
            Expanded(
              child: PageView(
                controller: ctl,
                onPageChanged: (i) => set(() => page = i),
                children: [
                  for (final p in _pages)
                    Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Icon(p.icon, size: 48),
                      const SizedBox(height: 16),
                      Text(p.title,
                          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 8),
                      Text(p.body, textAlign: TextAlign.center),
                    ]),
                ],
              ),
            ),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              for (var i = 0; i < _pages.length; i++)
                Container(
                  margin: const EdgeInsets.all(3),
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: i == page ? Colors.blue : Colors.grey.shade400),
                ),
            ]),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Skip')),
          FilledButton(
            onPressed: () {
              if (page == _pages.length - 1) {
                Navigator.pop(ctx);
              } else {
                ctl.nextPage(
                    duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
              }
            },
            child: Text(page == _pages.length - 1 ? 'Start' : 'Next'),
          ),
        ],
      ),
    ),
  );
}

Future<void> _showWhatsNew(BuildContext context, String version) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text("What's new in $version"),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [for (final n in _news) Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Text('• $n'))],
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
    ),
  );
}
