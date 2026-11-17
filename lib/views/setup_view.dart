import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/model_controller.dart';
import '../core/build_flavor.dart';
import '../models/ai_model.dart';
import '../core/ui.dart';
import '../services/agent_service.dart';
import '../services/device_bridge.dart';
import '../services/device_info_service.dart';
import '../services/download_queue.dart';
import '../services/hive_service.dart';
import '../services/memory_service.dart';
import '../services/sandbox_service.dart';
import '../services/voice_models.dart';
import 'quick_start.dart';

const kSetupDone = 'setup_done';

/// The settings most people want, chosen for this phone. Every switch starts
/// on the recommended value the first time; later the screen shows what is
/// set now, so you can change any of it.
class SetupView extends StatefulWidget {
  final bool firstRun;
  const SetupView({super.key, this.firstRun = false});

  @override
  State<SetupView> createState() => _SetupViewState();
}

class _SetupViewState extends State<SetupView> {
  final _hive = Get.find<HiveService>();
  late final double _ram = Get.find<DeviceInfoService>().totalRamGB.value;
  late final bool _setUpBefore = _hive.getSetting<bool>(kSetupDone) == true;
  bool _busy = false;

  // Downloads
  bool wifiOnly = true;
  bool chatModel = true;
  bool stt = true;
  bool ttsEn = true;
  bool ttsAr = true;
  bool vad = true;
  // Agent
  bool tools = true;
  bool autoMemory = true;
  bool memoryUpdate = true;
  bool sandbox = true;
  bool sandboxNoAsk = true;
  // Performance
  bool autoContext = true;
  bool autoTitle = true;
  bool loadLast = false;

  bool get _hasModel => Get.find<ModelController>().downloadedFiles.isNotEmpty;
  bool _has(String id) => Get.find<VoiceModelStore>().installed.contains(id);
  String get _sttId => _ram >= 6 ? 'whisper-base' : 'whisper-tiny';
  bool get _pro => SandboxService.supported;

  @override
  void initState() {
    super.initState();
    if (_setUpBefore) {
      // Show what is set now.
      final agent = Get.find<AgentService>();
      wifiOnly = _hive.getSetting<bool>('wifi_only', defaultValue: true) ?? true;
      tools = agent.mode.value != AgentChatMode.off;
      autoMemory = agent.autoMemory.value;
      memoryUpdate = MemoryService.ensure().enabled.value;
      autoContext = _hive.getSetting<bool>('auto_context', defaultValue: true) ?? true;
      autoTitle = _hive.getSetting<bool>('auto_title', defaultValue: true) ?? true;
      loadLast = _hive.getSetting<bool>('auto_load_last', defaultValue: false) ?? false;
      chatModel = false;
      stt = !_has(_sttId);
      ttsEn = !_has('piper-en-amy');
      ttsAr = !_has('piper-ar-kareem');
      vad = !_has('silero-vad');
      if (_pro) {
        final sb = Get.find<SandboxService>();
        sandbox = !sb.installed.value;
        sandboxNoAsk = agent.policyFor('built-in', 'run_shell', needsConfirm: true) == 'allow';
      }
    } else {
      chatModel = !_hasModel;
      stt = !_has(_sttId);
      ttsEn = !_has('piper-en-amy');
      ttsAr = !_has('piper-ar-kareem');
      vad = !_has('silero-vad');
    }
  }

  AiModel get _recommendedModel => quickStartModels(_ram).last;

  Future<void> _apply() async {
    setState(() => _busy = true);
    try {
      final agent = Get.find<AgentService>();
      await _hive.setSetting('wifi_only', wifiOnly);
      await _hive.setSetting('auto_context', autoContext);
      await _hive.setSetting('auto_title', autoTitle);
      await _hive.setSetting('auto_load_last', loadLast);
      await agent.setMode(tools ? AgentChatMode.auto : AgentChatMode.off);
      await agent.setAutoMemory(autoMemory);
      await MemoryService.ensure().setEnabled(memoryUpdate);
      if (_pro) {
        final p = sandboxNoAsk ? 'allow' : 'default';
        for (final t in const ['run_shell', 'run_script', 'install_packages', 'convert_file', 'create_tool', 'sandbox_setup']) {
          await agent.setPolicy('built-in', t, p);
        }
      }
      await _hive.setSetting(kSetupDone, true);
      await _hive.setSetting('quick_start_seen', true);

      // Only start big downloads on Wi-Fi when that is what the user asked for.
      var onWifi = true;
      if (wifiOnly) {
        try {
          final st = await Get.find<DeviceBridge>().status();
          onWifi = st.isEmpty || st['network'] == 'wifi' || st['network'] == 'ethernet';
        } catch (_) {}
      }
      final todo = <String>[];
      if (onWifi) {
        if (chatModel && !_hasModel) {
          Get.find<DownloadQueue>().add(_recommendedModel);
          todo.add('chat model');
        }
        final vs = Get.find<VoiceModelStore>();
        Future<void> dl(String id) async {
          final m = voiceModelById(id);
          if (m == null || _has(id)) return;
          todo.add(m.title.split('(').first.trim());
          await _hive.setSetting(m.kind == VoiceKind.stt ? 'voice_stt_id' : 'voice_tts_id', id);
          vs.download(m); // runs in the background
        }

        if (stt) await dl(_sttId);
        if (ttsEn) await dl('piper-en-amy');
        if (ttsAr) await dl('piper-ar-kareem');
        if (vad) await dl('silero-vad');
        if (_pro && sandbox) {
          final sb = Get.find<SandboxService>();
          if (!sb.installed.value) {
            todo.add('Linux sandbox');
            _installSandbox(sb);
          }
        }
      } else if (chatModel || stt || ttsEn || ttsAr || vad || sandbox) {
        Get.snackbar('Waiting for Wi-Fi',
            'Settings saved. Downloads were not started because Wi-Fi only is on and you are not on Wi-Fi. Open this screen again on Wi-Fi.',
            duration: const Duration(seconds: 6));
      }
      if (todo.isNotEmpty) {
        Get.snackbar('Downloading in the background', todo.join(', '),
            duration: const Duration(seconds: 5));
      }
      if (mounted) Get.back();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _installSandbox(SandboxService sb) async {
    try {
      await sb.install();
      sb.busy.value = true;
      sb.status.value = 'Installing tools…';
      await sb.run('apk update >/dev/null 2>&1; apk add --no-cache ${sandboxProfiles['basic']}', timeoutSec: 1200);
    } catch (e) {
      Get.snackbar('Sandbox setup failed', '$e'.replaceFirst('Exception: ', ''));
    } finally {
      sb.busy.value = false;
      sb.status.value = 'Ready';
    }
  }

  Widget _sw(IconData icon, String title, String sub, bool v, void Function(bool) on, {bool rec = true}) =>
      AppRow(
        icon: icon,
        title: rec ? '$title  ·  recommended' : title,
        subtitle: sub,
        trailing: Switch(value: v, onChanged: (x) => setState(() => on(x))),
      );

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final rec = _recommendedModel;
    return Scaffold(
      backgroundColor: t.bg,
      appBar: appScreenBar(context,
          title: widget.firstRun ? 'Set up NeuroMesh' : 'Setup & recommended settings',
          showBack: !widget.firstRun),
      body: ListView(padding: kPagePadding, children: [
        AppNotice(widget.firstRun || !_setUpBefore
            ? 'These are the settings that suit your phone (${_ram.toStringAsFixed(1)} GB RAM). Everything is on by default; turn off what you do not want. You can change all of it later in Settings → Setup.'
            : 'Your current settings. Switches for downloads are on only for things you have not installed yet.'),
        const SectionHeader('Downloads'),
        AppGroup(children: [
          _sw(Icons.wifi_rounded, 'Download over Wi-Fi only', 'Big files never use mobile data', wifiOnly, (v) => wifiOnly = v),
          if (!_hasModel || _setUpBefore)
            _sw(Icons.chat_bubble_outline_rounded, 'Small chat model: ${rec.name}', '${rec.size}. Fits your phone and runs fast.', chatModel, (v) => chatModel = v),
          _sw(Icons.hearing_rounded, 'Listening (speech to text)', '${voiceModelById(_sttId)?.title ?? _sttId}  ·  ${voiceModelById(_sttId)?.sizeLabel ?? ''}${_has(_sttId) ? '  ·  installed' : ''}', stt, (v) => stt = v),
          _sw(Icons.record_voice_over_rounded, 'English voice', 'Piper Amy  ·  67 MB${_has('piper-en-amy') ? '  ·  installed' : ''}', ttsEn, (v) => ttsEn = v),
          _sw(Icons.record_voice_over_rounded, 'Arabic voice', 'Piper Kareem  ·  67 MB${_has('piper-ar-kareem') ? '  ·  installed' : ''}', ttsAr, (v) => ttsAr = v),
          _sw(Icons.graphic_eq_rounded, 'Smart speech detector', 'Makes calls feel natural  ·  1 MB${_has('silero-vad') ? '  ·  installed' : ''}', vad, (v) => vad = v),
        ]),
        const SectionHeader('Agent'),
        AppGroup(children: [
          _sw(Icons.handyman_outlined, 'Let the AI use tools', 'Files, web search, voice, images. It only uses them when needed.', tools, (v) => tools = v),
          _sw(Icons.psychology_alt_rounded, 'Remember things I tell it', 'Saves short facts about you on this device', autoMemory, (v) => autoMemory = v),
          _sw(Icons.update_rounded, 'Update memory automatically', 'Reads recent chats once a day', memoryUpdate, (v) => memoryUpdate = v),
          if (_pro) ...[
            _sw(Icons.terminal_rounded, 'Install the Linux sandbox', 'About 150 MB with python, node, git. One shared sandbox for every chat.', sandbox, (v) => sandbox = v),
            _sw(Icons.bolt_rounded, 'Run sandbox commands without asking', 'Commands run in an isolated Linux, not on your phone files', sandboxNoAsk, (v) => sandboxNoAsk = v),
          ] else if (kProBuild)
            const AppRow(icon: Icons.terminal_rounded, title: 'Linux sandbox', subtitle: 'Available on Android in the Pro build'),
        ]),
        const SectionHeader('Performance'),
        AppGroup(children: [
          _sw(Icons.memory_rounded, 'Auto context size', 'Lowers the context if the model would not fit in RAM', autoContext, (v) => autoContext = v),
          _sw(Icons.title_rounded, 'Auto-title chats', 'Names new chats for you', autoTitle, (v) => autoTitle = v),
          _sw(Icons.play_circle_outline_rounded, 'Load last model on start', 'Opens ready to chat but uses RAM right away', loadLast, (v) => loadLast = v, rec: false),
        ]),
        const SizedBox(height: 16),
        PrimaryButton(label: _setUpBefore && !widget.firstRun ? 'Save' : 'Apply recommended settings', icon: Icons.check_rounded, busy: _busy, onPressed: _apply),
        if (widget.firstRun)
          TextButton(
              onPressed: () async {
                await _hive.setSetting(kSetupDone, true);
                Get.back();
              },
              child: const Text('Skip for now')),
        const SizedBox(height: 24),
      ]),
    );
  }
}

/// Opens the setup screen once, for people who have not seen it yet.
Future<void> maybeShowSetup() async {
  final hive = Get.find<HiveService>();
  if (hive.getSetting<bool>(kSetupDone) == true) return;
  await Get.to(() => const SetupView(firstRun: true));
  await hive.setSetting(kSetupDone, true);
}
