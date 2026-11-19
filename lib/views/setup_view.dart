import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/model_controller.dart';
import '../models/ai_model.dart';
import '../core/ui.dart';
import '../services/agent_service.dart';
import '../services/app_log_service.dart';
import '../services/device_bridge.dart';
import '../services/device_info_service.dart';
import '../services/download_queue.dart';
import '../services/hive_service.dart';
import '../services/memory_service.dart';
import '../services/sandbox_service.dart';
import '../services/voice_models.dart';
import '../core/constants.dart';
import 'chat_tools.dart';

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
  String? _saveError;

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
  bool? _alpineAvailable;
  bool sandbox = false;
  late bool sandboxTools =
      _hive.getSetting<bool>(SandboxService.basicToolsInstalledKey) != true;
  bool sandboxNoAsk = false;
  bool _sandboxPermissionChanged = false;
  // Performance
  bool autoContext = true;
  bool autoTitle = true;
  bool loadLast = false;

  bool get _artemisReady {
    final models = Get.find<ModelController>();
    return models.isDownloaded(_recommendedModel.filename) &&
        models.isVisionFileReady(_recommendedModel);
  }
  bool _has(String id) => Get.find<VoiceModelStore>().installed.contains(id);
  String get _sttId => _ram >= 6 ? 'whisper-base' : 'whisper-tiny';
  bool get _pro => SandboxService.supported;

  @override
  void initState() {
    super.initState();
    if (_pro) {
      final alpine = Get.find<SandboxService>();
      sandboxNoAsk = Get.find<AgentService>()
              .policyFor('built-in', 'run_shell', needsConfirm: true) ==
          'allow';
      unawaited(alpine.runtimeAvailable().then((available) {
        if (!mounted) return;
        setState(() {
          _alpineAvailable = available;
          sandbox = available && !alpine.installed.value;
        });
      }));
    }
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
      chatModel = !_artemisReady;
      stt = !_has(_sttId);
      ttsEn = !_has('piper-en-amy');
      ttsAr = !_has('piper-ar-kareem');
      vad = !_has('silero-vad');
    } else {
      chatModel = !_artemisReady;
      stt = !_has(_sttId);
      ttsEn = !_has('piper-en-amy');
      ttsAr = !_has('piper-ar-kareem');
      vad = !_has('silero-vad');
    }
  }

  final _recommendedModel = AiModel.fromMap(AppConstants.artemisStarter);

  Future<void> _apply() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _saveError = null;
    });
    var closed = false;
    try {
      final agent = Get.find<AgentService>();
      await _hive.settingsBox.putAll({
        'wifi_only': wifiOnly,
        'auto_context': autoContext,
        'auto_title': autoTitle,
        'auto_load_last': loadLast,
      });
      await agent.setMode(tools ? AgentChatMode.auto : AgentChatMode.off);
      await agent.setAutoMemory(autoMemory);
      await MemoryService.ensure().setEnabled(memoryUpdate);
      if (_alpineAvailable == true && _sandboxPermissionChanged) {
        final policy = sandboxNoAsk ? 'allow' : 'default';
        for (final tool in const [
          'run_shell', 'run_script', 'install_packages', 'convert_file',
          'create_tool', 'sandbox_setup',
        ]) {
          await agent.setPolicy('built-in', tool, policy);
        }
      }
      final language = _hive.getSetting<String>('voice_lang') ?? 'en';
      final tts = ttsAr && (!ttsEn || language == 'ar')
          ? 'piper-ar-kareem'
          : ttsEn
              ? 'piper-en-amy'
              : null;
      await _hive.settingsBox.putAll({
        if (stt && (_hive.getSetting<String>('voice_stt_id') ?? '').isEmpty)
          'voice_stt_id': _sttId,
        if (tts != null && (_hive.getSetting<String>('voice_tts_id') ?? '').isEmpty)
          'voice_tts_id': tts,
        kSetupDone: true,
        'quick_start_seen': true,
      });
      if (!mounted) return;

      final messenger = ScaffoldMessenger.maybeOf(context);
      Navigator.of(context).pop();
      closed = true;
      unawaited(_startDownloads(messenger));
    } catch (error) {
      Get.find<AppLogService>().error('Could not apply recommended settings',
          details: error);
      if (mounted) {
        setState(() => _saveError = 'Could not save your settings. Try again.');
      }
    } finally {
      if (mounted && !closed) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _startDownloads(ScaffoldMessengerState? messenger) async {
    final voiceIds = [
      if (stt && !_has(_sttId)) _sttId,
      if (ttsEn && !_has('piper-en-amy')) 'piper-en-amy',
      if (ttsAr && !_has('piper-ar-kareem')) 'piper-ar-kareem',
      if (vad && !_has('silero-vad')) 'silero-vad',
    ];
    final useChatModel = chatModel && !_artemisReady;
    final alpine = _alpineAvailable == true ? Get.find<SandboxService>() : null;
    final installSandbox = alpine != null && sandbox && !alpine.installed.value;
    final installTools = alpine != null && sandboxTools &&
        (alpine.installed.value || installSandbox);
    void notify(String message) {
      if (messenger?.mounted == true) {
        messenger!.showSnackBar(SnackBar(content: Text(message)));
      }
    }

    try {
      if (!useChatModel && voiceIds.isEmpty && !installSandbox && !installTools) {
        notify('Settings applied.');
        return;
      }
      if (wifiOnly && Platform.isAndroid) {
        final status = await Get.find<DeviceBridge>().status()
            .timeout(const Duration(seconds: 3), onTimeout: () => {});
        final network = status['network'];
        if (network != 'wifi' && network != 'ethernet') {
          notify('Settings applied. Connect to Wi-Fi and reopen Setup to start downloads.');
          return;
        }
      }

      if (useChatModel) Get.find<DownloadQueue>().add(_recommendedModel);
      final store = Get.find<VoiceModelStore>();
      for (final id in voiceIds) {
        final model = voiceModelById(id);
        if (model != null) unawaited(store.download(model).catchError((Object error) {
          Get.find<AppLogService>().error('Voice model download could not start',
              details: error);
        }));
      }
      if (alpine != null && (installSandbox || installTools)) {
        unawaited(_installSandbox(alpine, withTools: installTools));
      }
      notify('Settings applied. Selected downloads are starting.');
    } catch (error) {
      Get.find<AppLogService>().error('Setup downloads could not start',
          details: error);
      notify('Settings applied. Reopen Setup to retry the downloads.');
    }
  }

  Future<void> _skip() async {
    if (_busy) return;
    try {
      setState(() => _busy = true);
      await _hive.setSetting(kSetupDone, true);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _saveError = 'Could not save your choice. Try again.';
        });
      }
    }
  }

  Future<void> _installSandbox(SandboxService sb, {required bool withTools}) async {
    try {
      await sb.install();
      await _hive.setSetting('restore_alpine_recommended', false);
      if (withTools) {
        final result = await sb.run(
          'apk add --no-cache ${sandboxProfiles['basic']}',
          timeoutSec: 1200,
        );
        if (!result.trimRight().endsWith('[exit code 0]')) {
          Get.find<AppLogService>().warning('Alpine developer tools setup failed',
              details: result);
          Get.snackbar('Alpine is installed', 'The developer tools could not be installed. You can retry from Setup.');
        } else {
          await _hive.setSetting(SandboxService.basicToolsInstalledKey, true);
        }
      }
    } catch (error) {
      Get.snackbar('Alpine setup failed', '$error'.replaceFirst('Exception: ', ''));
    }
  }

  Widget _alpineDownloads() {
    if (_alpineAvailable != true) {
      return AppRow(
        icon: Icons.terminal_rounded,
        title: 'Alpine Linux',
        subtitle: _alpineAvailable == null && _pro
            ? 'Checking the Android runtime…'
            : 'Available in the ARM64 Android build',
      );
    }
    final alpine = Get.find<SandboxService>();
    return Obx(() => Column(children: [
          if (alpine.installed.value)
            AppRow(
              icon: Icons.terminal_rounded,
              title: 'Alpine Linux installed',
              subtitle: 'Open the terminal',
              chevron: true,
              onTap: () => Get.to(() => const AlpineTerminalView()),
            )
          else if (alpine.busy.value)
            AppRow(
              icon: Icons.terminal_rounded,
              title: 'Installing Alpine Linux',
              subtitle: alpine.status.value,
              trailing: SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(
                    value: alpine.downloadProgress.value),
              ),
            )
          else
            _sw(
                Icons.terminal_rounded,
                'Install Alpine Linux',
                _hive.getSetting<bool>('restore_alpine_recommended') == true
                    ? 'Your previous device used Alpine. Reinstall it to open the restored workspace in the terminal.'
                    : 'About 4 MB. Opens a local terminal that shares this chat’s workspace.',
                sandbox,
                (value) => sandbox = value),
          if (alpine.installed.value || (sandbox && !alpine.busy.value))
            _sw(
                Icons.code_rounded,
                'Alpine developer tools',
                'Python, Node.js, Git and other command-line tools for the terminal and agent.',
                sandboxTools,
                (value) => sandboxTools = value,
                rec: true),
        ]));
  }

  Widget _sw(IconData icon, String title, String sub, bool v, void Function(bool) on, {bool rec = true}) =>
      AppRow(
        icon: icon,
        title: rec ? '$title  ·  recommended' : title,
        subtitle: sub,
        trailing: Switch(value: v, onChanged: _busy ? null : (x) => setState(() => on(x))),
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
            ? 'These are the settings that suit your phone (${_ram.toStringAsFixed(1)} GB RAM). Review the selected downloads and settings before applying them. You can change all of it later in Settings → Setup.'
            : 'Your current settings. Switches for downloads are on only for things you have not installed yet.'),
        const SectionHeader('Downloads'),
        AppGroup(children: [
          _sw(Icons.wifi_rounded, 'Download over Wi-Fi only', 'Big files never use mobile data', wifiOnly, (v) => wifiOnly = v),
          if (_artemisReady)
            AppRow(
              icon: Icons.chat_bubble_outline_rounded,
              title: rec.name,
              subtitle: 'Model and vision helper installed',
            )
          else
            _sw(Icons.chat_bubble_outline_rounded, rec.name,
                '532 MB model and 207 MB matching vision helper',
                chatModel, (value) => chatModel = value),
          _sw(Icons.hearing_rounded, 'Listening (speech to text)', '${voiceModelById(_sttId)?.title ?? _sttId}  ·  ${voiceModelById(_sttId)?.sizeLabel ?? ''}${_has(_sttId) ? '  ·  installed' : ''}', stt, (v) => stt = v),
          _sw(Icons.record_voice_over_rounded, 'English voice', 'Piper Amy  ·  67 MB${_has('piper-en-amy') ? '  ·  installed' : ''}', ttsEn, (v) => ttsEn = v),
          _sw(Icons.record_voice_over_rounded, 'Arabic voice', 'Piper Kareem  ·  67 MB${_has('piper-ar-kareem') ? '  ·  installed' : ''}', ttsAr, (v) => ttsAr = v),
          _sw(Icons.graphic_eq_rounded, 'Smart speech detector', 'Makes calls feel natural  ·  1 MB${_has('silero-vad') ? '  ·  installed' : ''}', vad, (v) => vad = v),
          _alpineDownloads(),
        ]),
        const SectionHeader('Agent'),
        AppGroup(children: [
          _sw(Icons.handyman_outlined, 'Let the AI use tools', 'Files, web search, voice, images, and Alpine commands when the terminal is installed.', tools, (v) => tools = v),
          _sw(Icons.psychology_alt_rounded, 'Remember things I tell it', 'Saves short facts about you on this device', autoMemory, (v) => autoMemory = v),
          _sw(Icons.update_rounded, 'Update memory automatically', 'Reads recent chats once a day', memoryUpdate, (v) => memoryUpdate = v),
          if (_alpineAvailable == true)
            _sw(Icons.bolt_rounded, 'Run sandbox commands without asking',
                'Controls whether the agent asks before running commands in Alpine.',
                sandboxNoAsk, (value) {
                  sandboxNoAsk = value;
                  _sandboxPermissionChanged = true;
                }, rec: false),
        ]),
        const SectionHeader('Performance'),
        AppGroup(children: [
          _sw(Icons.memory_rounded, 'Auto context size', 'Lowers the context if the model would not fit in RAM', autoContext, (v) => autoContext = v),
          _sw(Icons.title_rounded, 'Auto-title chats', 'Names new chats for you', autoTitle, (v) => autoTitle = v),
          _sw(Icons.play_circle_outline_rounded, 'Load last model on start', 'Opens ready to chat but uses RAM right away', loadLast, (v) => loadLast = v, rec: false),
        ]),
        const SizedBox(height: 16),
        if (_saveError case final message?)
          AppNotice(message, icon: Icons.error_outline_rounded),
        PrimaryButton(label: _setUpBefore && !widget.firstRun ? 'Save' : 'Apply recommended settings', icon: Icons.check_rounded, busy: _busy, onPressed: _pro && _alpineAvailable == null ? null : _apply),
        if (widget.firstRun)
          TextButton(
              onPressed: _busy ? null : _skip,
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
}
