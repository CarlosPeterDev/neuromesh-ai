import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/home_controller.dart';
import '../services/cluster_service.dart';
import '../services/sandbox_service.dart';
import '../views/chat_tools.dart';
import '../views/cluster_view.dart';
import '../views/log_view.dart';
import '../views/memory_view.dart';
import '../views/model_transfer_view.dart';
import '../views/roles_view.dart';
import '../views/perf_views.dart';
import '../views/relay_view.dart';
import '../views/scheduled_tasks_view.dart';
import '../views/storage_view.dart';
import '../views/toolbox_view.dart';
import '../views/voice_clone_view.dart';
import '../views/voice_views.dart';

/// Bottom-bar tabs of the home screen.
abstract class HomeTab {
  static const chat = 0;
  static const models = 1;
  static const server = 2;
  static const settings = 3;
}

/// One place in the app. Either opens [page] on top, or switches to a home [tab].
class NavEntry {
  final String title;
  final String subtitle;
  final IconData icon;
  final Widget Function()? page;
  final int? tab;
  const NavEntry(this.title, this.subtitle, this.icon, {this.page, this.tab});

  /// Opens this entry from anywhere (drawer, settings, toolbox).
  void open() {
    final t = tab;
    if (t != null) {
      Get.until((r) => r.isFirst);
      Get.find<HomeController>().changeTab(t);
      return;
    }
    final p = page;
    if (p != null) Get.to(p);
  }
}

class NavSection {
  final String title;
  final IconData icon;
  final List<NavEntry> entries;
  const NavSection(this.title, this.icon, this.entries);
}

/// Every screen of the app, grouped. The drawer's Menu tab renders this list,
/// so adding a screen here makes it appear in the menu.
///
/// To add a new screen, add one NavEntry below.
List<NavSection> buildNavSections() => [
      NavSection('AI & agent', Icons.auto_awesome_rounded, [
        NavEntry('Agent tools & permissions',
            'What the AI may do, per tool', Icons.handyman_outlined,
            page: () => const ChatToolsView()),
        NavEntry('MCP servers', 'Connect apps and services',
            Icons.extension_outlined,
            page: () => const ChatToolsView()),
        NavEntry('Scheduled tasks', 'Automation that runs by itself',
            Icons.schedule_rounded,
            page: () => const ScheduledTasksView()),
        NavEntry('Memory', 'What the AI remembers about you',
            Icons.psychology_alt_rounded,
            page: () => const MemoryView()),
        NavEntry('Roles', 'Your own personas for chats',
            Icons.theater_comedy_outlined,
            page: () => const RolesView()),
        if (SandboxService.supported)
          NavEntry('Linux sandbox', 'Run real commands (Pro build)',
              Icons.terminal_rounded,
              page: () => const ChatToolsView()),
      ]),
      NavSection('Models & voice', Icons.layers_rounded, [
        NavEntry('Models', 'Chat models, Hugging Face, image models',
            Icons.layers_outlined,
            tab: HomeTab.models),
        NavEntry('Voice call', 'Talk hands-free', Icons.call_outlined,
            page: () => const VoiceCallView()),
        NavEntry('Voice models', 'Listening and speaking models',
            Icons.record_voice_over_outlined,
            page: () => const VoiceModelsView()),
        NavEntry('Transfer models', 'Send models to another device',
            Icons.swap_horiz_rounded,
            page: () => const ModelTransferView()),
        NavEntry('Voice cloning', 'Speak in your own voice',
            Icons.mic_external_on_rounded,
            page: () => const VoiceCloneView()),
        NavEntry('Compare models', 'Same prompt, two answers',
            Icons.compare_rounded,
            page: () => const CompareView()),
      ]),
      NavSection('Connect', Icons.hub_outlined, [
        NavEntry('Server & API', 'Use the AI from other apps',
            Icons.lan_outlined,
            tab: HomeTab.server),
        NavEntry('Remote access', 'Reach your phone from outside',
            Icons.public_rounded,
            page: () => const RelayView()),
        if (Get.isRegistered<ClusterService>())
          NavEntry('Phone cluster', 'Share a model across devices',
              Icons.device_hub_rounded,
              page: () => const ClusterView()),
      ]),
      NavSection('App', Icons.settings_outlined, [
        NavEntry('Settings', 'Appearance, inference, voice, updates',
            Icons.settings_outlined,
            tab: HomeTab.settings),
        NavEntry('Toolbox', 'Export, backup, benchmark, utilities',
            Icons.handyman_rounded,
            page: () => const ToolboxView()),
        NavEntry('Storage', 'Downloaded models and space',
            Icons.sd_storage_outlined,
            page: () => const StorageView()),
        NavEntry('Logs', 'What the app has been doing', Icons.article_outlined,
            page: () => const LogView()),
      ]),
    ];
