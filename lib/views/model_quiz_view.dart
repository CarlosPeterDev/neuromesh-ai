import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/home_controller.dart';
import '../controllers/model_controller.dart';
import '../core/constants.dart';
import '../models/ai_model.dart';
import '../services/device_bridge.dart';
import '../services/device_info_service.dart';
import 'agent_hub_view.dart';

enum StarterUse { chat, code, learn, write, camera }

typedef StarterChoice = ({AiModel model, double ram, int bytes});

List<StarterChoice> recommendStarters({
  required StarterUse use,
  required bool preferSpeed,
  required double availableRam,
  required double totalRam,
  required int freeBytes,
}) {
  bool fits(StarterChoice choice) {
    final ram = availableRam > 0 ? availableRam : totalRam * .55;
    return (ram == 0 || ram >= choice.ram) &&
        (freeBytes == 0 || freeBytes >= choice.bytes + 200000000);
  }

  StarterChoice catalog(String file, double ram, int bytes, {String? size}) {
    final data = AppConstants.availableModels
        .firstWhere((item) => item['filename'] == file);
    return (
      model: AiModel.fromMap({...data, if (size != null) 'size': size}),
      ram: ram,
      bytes: bytes,
    );
  }

  StarterChoice community(String name, String repository, String filename,
          String size, String template, double ram, int bytes) =>
      (
        model: AiModel.fromMap({
          'name': name,
          'filename': filename,
          'url': 'https://huggingface.co/$repository/resolve/main/$filename',
          'size': size,
          'template': template,
        }),
        ram: ram,
        bytes: bytes,
      );

  StarterChoice coder(String parameters, double ram, int bytes, String size) {
    final name = 'Qwen2.5-Coder-$parameters-Instruct';
    return community('Qwen 2.5 Coder $parameters', 'Qwen/$name-GGUF',
        '${name.toLowerCase()}-q4_k_m.gguf', size, 'chatml', ram, bytes);
  }

  final smol = community('SmolLM2 360M', 'bartowski/SmolLM2-360M-Instruct-GGUF',
      'SmolLM2-360M-Instruct-Q4_K_M.gguf', '271 MB', 'chatml', .85, 271000000);
  final liquid = catalog('lfm2.5-1.2b-instruct-q4_k_m.gguf', 1.6, 731000000);
  final gemma = catalog('gemma-3-1b-it-q4_0.gguf', 1.65, 722000000);
  final llama = catalog('llama-3.2-1b-instruct-q4_k_m.gguf', 1.75, 808000000,
      size: '808 MB');
  final phi = catalog('phi-3.5-mini-instruct-q4_k_m.gguf', 3.8, 2394000000,
      size: '2.39 GB');
  final qwenFast = coder('0.5B', 1, 492000000, '492 MB');
  final qwenCode = coder('1.5B', 2.1, 1118000000, '1.12 GB');

  final candidates = switch (use) {
    StarterUse.chat => [liquid, gemma, llama, smol],
    StarterUse.learn => [phi, gemma, llama, smol],
    StarterUse.write => [llama, gemma, liquid, smol],
    StarterUse.code => [qwenCode, phi, qwenFast, liquid],
    StarterUse.camera => [
        catalog('gemma-3-4b-it-q4_k_m.gguf', 4.5, 3342000000),
        catalog('lfm2.5-vl-1.6b-q4_k_m.gguf', 2.6, 1315000000),
        (
          model: AiModel.fromMap(AppConstants.artemisStarter),
          ram: 2.2,
          bytes: 740000000
        ),
      ],
  }
      .where(fits)
      .toList();
  if (preferSpeed) candidates.sort((a, b) => a.bytes.compareTo(b.bytes));
  return candidates.take(4).toList();
}

class ModelQuizView extends StatefulWidget {
  const ModelQuizView({super.key, this.welcome = false});

  final bool welcome;

  @override
  State<ModelQuizView> createState() => _ModelQuizViewState();
}

class _ModelQuizViewState extends State<ModelQuizView> {
  late int _step = widget.welcome ? 0 : 1;
  StarterUse? _use;
  String? _selectedModel;
  bool _preferSpeed = false;
  bool _checking = true;
  int _storage = 0;
  double _total = 0;
  double _available = 0;

  String _t(String en, String ar) => agentHubUsesArabic(context) ? ar : en;

  @override
  void initState() {
    super.initState();
    unawaited(_readDevice());
  }

  Future<void> _readDevice() async {
    final device = Get.find<DeviceInfoService>();
    try {
      await device.refreshMemoryInfo();
      final info = await Get.find<DeviceBridge>().status();
      _storage = (info['storageFree'] as num?)?.toInt() ?? 0;
    } on Exception {
      // Unknown storage is shown as unavailable and rechecked by the downloader.
    } finally {
      if (mounted) {
        setState(() {
          _total = device.totalRamGB.value;
          _available = device.availableRamGB.value;
          _checking = false;
        });
      }
    }
  }

  void _browse() {
    Navigator.pop(context);
    Get.find<HomeController>().changeTab(1);
  }

  void _useModel(AiModel model, bool installed) {
    final models = Get.find<ModelController>();
    Navigator.pop(context);
    Get.find<HomeController>().changeTab(1);
    if (installed) {
      unawaited(models.loadModel(model.filename));
    } else {
      unawaited(models.downloadModel(model));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        leading: _step > (widget.welcome ? 0 : 1)
            ? BackButton(onPressed: () => setState(() => _step--))
            : null,
        automaticallyImplyLeading: false,
        actions: [
          Semantics(
            identifier: 'neuromesh.onboarding.skip',
            child: TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(_t('Skip for now', 'تخطَّ الآن')),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
              children: [
                if (_step == 0) ..._welcome(scheme),
                if (_step == 1) ..._questions(scheme),
                if (_step == 2) ..._result(scheme),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _welcome(ColorScheme scheme) => [
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: CircleAvatar(
            radius: 31,
            backgroundColor: scheme.primaryContainer,
            foregroundColor: scheme.onPrimaryContainer,
            child: const Icon(Icons.hub_rounded, size: 32),
          ),
        ),
        const SizedBox(height: 22),
        _headline(_t('Welcome to NeuroMesh', 'مرحبًا بك في NeuroMesh')),
        const SizedBox(height: 10),
        Text(_t('Choose a model that fits your device and what you want to do.',
            'اختر نموذجًا يناسب جهازك وما تريد فعله.')),
        const SizedBox(height: 22),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.offline_bolt_outlined),
          title: Text(_t('Local chat, even offline', 'دردشة محلية دون اتصال')),
          subtitle: Text(_t('Download a model once and run it on your device.',
              'نزّل النموذج مرة واحدة وشغّله على جهازك.')),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.graphic_eq_rounded),
          title:
              Text(_t('Talk or share your camera', 'تحدّث أو شارك الكاميرا')),
          subtitle: Text(_t('Voice and camera work with compatible models.',
              'يعمل الصوت والكاميرا مع النماذج المتوافقة.')),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.terminal_rounded),
          title: Text(_t('Connect OpenCode', 'اتصل بـ OpenCode')),
          subtitle: Text(_t('Use an existing OpenCode server when you need it.',
              'استخدم خادم OpenCode قائمًا عند الحاجة.')),
        ),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: () => setState(() => _step = 1),
          child: Text(_t('Help me choose a model', 'ساعدني في اختيار نموذج')),
        ),
      ];

  List<Widget> _questions(ColorScheme scheme) => [
        _headline(_t('What will you use it for?', 'فيمَ ستستخدم التطبيق؟')),
        const SizedBox(height: 16),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final option in [
            (
              StarterUse.chat,
              Icons.chat_bubble_outline,
              _t('Everyday chat', 'دردشة يومية')
            ),
            (StarterUse.code, Icons.code, _t('Coding', 'برمجة')),
            (StarterUse.learn, Icons.school_outlined, _t('Learning', 'تعلّم')),
            (StarterUse.write, Icons.edit_outlined, _t('Writing', 'كتابة')),
            (
              StarterUse.camera,
              Icons.camera_alt_outlined,
              _t('Camera and images', 'كاميرا وصور')
            ),
          ])
            ChoiceChip(
              label: Text(option.$3),
              avatar: Icon(option.$2, size: 20),
              selected: _use == option.$1,
              onSelected: (_) => setState(() => _use = option.$1),
            ),
        ]),
        const SizedBox(height: 28),
        _headline(_t('What matters most?', 'ما الأهم لك؟')),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          ChoiceChip(
            label: Text(_t('Smaller and faster', 'أصغر وأسرع')),
            selected: _preferSpeed,
            onSelected: (_) => setState(() => _preferSpeed = true),
          ),
          ChoiceChip(
            label: Text(_t(
                'Better answers when possible', 'إجابات أفضل عندما يمكن ذلك')),
            selected: !_preferSpeed,
            onSelected: (_) => setState(() => _preferSpeed = false),
          ),
        ]),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _use == null || _checking
              ? null
              : () => setState(() => _step = 2),
          child: Text(_checking
              ? _t('Checking your device…', 'جارٍ فحص جهازك…')
              : _t('Show my recommendation', 'اعرض النموذج المقترح')),
        ),
      ];

  List<Widget> _result(ColorScheme scheme) {
    final candidates = recommendStarters(
        use: _use!,
        preferSpeed: _preferSpeed,
        availableRam: _available,
        totalRam: _total,
        freeBytes: _storage);
    final choice = candidates.firstWhereOrNull(
            (choice) => choice.model.filename == _selectedModel) ??
        candidates.firstOrNull;
    return [
      _headline(_t('Your starting model', 'نموذجك للبدء')),
      const SizedBox(height: 12),
      if (_total > 0)
        Text(_t('${_total.toStringAsFixed(1)} GB RAM',
            'ذاكرة ${_total.toStringAsFixed(1)} غيغابايت')),
      if (_storage > 0)
        Text(_t('${(_storage / 1e9).toStringAsFixed(1)} GB free storage',
            'مساحة تخزين حرة ${(_storage / 1e9).toStringAsFixed(1)} غيغابايت')),
      const SizedBox(height: 20),
      if (choice == null)
        Text(_t(
            'No starter model fits the reported memory or storage for this choice.',
            'لا يوجد نموذج بدء يناسب الذاكرة أو التخزين المتاح لهذا الخيار.'))
      else ...[
        for (final candidate in candidates)
          Card(
            color: candidate == choice ? scheme.primaryContainer : null,
            child: ListTile(
              selected: candidate == choice,
              leading: Icon(candidate == choice
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked),
              title: Text(candidate.model.name),
              subtitle: Text(candidate.model.size),
              onTap: () =>
                  setState(() => _selectedModel = candidate.model.filename),
            ),
          ),
        const SizedBox(height: 12),
        Obx(() {
          final models = Get.find<ModelController>();
          final model = choice.model;
          final installed = models.isDownloaded(model.filename) &&
              (!model.hasVisionProjector || models.isVisionFileReady(model));
          return FilledButton.icon(
            icon: Icon(
                installed ? Icons.play_arrow_rounded : Icons.download_rounded),
            label: Text(installed
                ? _t('Use installed model', 'استخدم النموذج المثبّت')
                : _t('Download ${model.size}', 'تنزيل ${model.size}')),
            onPressed: () => _useModel(model, installed),
          );
        }),
      ],
      TextButton(
          onPressed: _browse,
          child: Text(_t('Browse models', 'تصفّح النماذج'))),
    ];
  }

  Widget _headline(String text) =>
      Text(text, style: Theme.of(context).textTheme.headlineMedium);
}
