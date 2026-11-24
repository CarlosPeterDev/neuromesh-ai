import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/model_controller.dart';
import '../models/ai_model.dart';
import '../core/ui.dart';
import '../services/chat_tool_service.dart';
import '../services/app_log_service.dart';
import '../services/device_bridge.dart';
import '../services/device_info_service.dart';
import '../services/download_queue.dart';
import '../services/hive_service.dart';
import '../services/memory_service.dart';
import '../services/voice_models.dart';
import '../core/constants.dart';

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
  // Chat
  bool tools = true;
  bool memoryUpdate = true;
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

  @override
  void initState() {
    super.initState();
    if (_setUpBefore) {
      // Show what is set now.
      final agent = Get.find<ChatToolService>();
      wifiOnly = _hive.getSetting<bool>('wifi_only', defaultValue: true) ?? true;
      tools = agent.mode.value != ChatToolMode.off;
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
      final agent = Get.find<ChatToolService>();
      await _hive.settingsBox.putAll({
        'wifi_only': wifiOnly,
        'auto_context': autoContext,
        'auto_title': autoTitle,
        'auto_load_last': loadLast,
      });
      await agent.setMode(tools ? ChatToolMode.auto : ChatToolMode.off);
      await MemoryService.ensure().setEnabled(memoryUpdate);

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
    void notify(String message) {
      if (messenger?.mounted == true) {
        messenger!.showSnackBar(SnackBar(content: Text(message)));
      }
    }

    try {
      if (!useChatModel && voiceIds.isEmpty) {
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
        ]),
        const SectionHeader('Chat'),
        AppGroup(children: [
          _sw(Icons.handyman_outlined, 'Let the AI use tools', 'Web search, calculations, attachments, speech, and images.', tools, (v) => tools = v),
          _sw(Icons.update_rounded, 'Update memory automatically', 'Reads recent chats once a day', memoryUpdate, (v) => memoryUpdate = v),
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
        PrimaryButton(label: _setUpBefore && !widget.firstRun ? 'Save' : 'Apply recommended settings', icon: Icons.check_rounded, busy: _busy, onPressed: _apply),
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
