import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:url_launcher/url_launcher.dart';

import '../controllers/model_controller.dart';
import '../core/ui.dart';
import '../models/ai_model.dart';
import '../services/download_service.dart';
import '../services/hf_service.dart';
import '../services/model_helper_service.dart';
import '../utils/model_file_role.dart';
import 'hf_browser.dart';

class ModelHelpersView extends StatefulWidget {
  const ModelHelpersView({super.key, required this.model});
  final AiModel model;

  @override
  State<ModelHelpersView> createState() => _ModelHelpersViewState();
}

class _ModelHelpersViewState extends State<ModelHelpersView> {
  final _hf = HfService();
  late final _query =
      TextEditingController(text: ModelHelperService.searchQuery(widget.model));
  List<HfRepo> _repos = [];
  List<HfGgufFile> _files = [];
  String? _repository;
  String? _error;
  bool _busy = false;
  int _request = 0;
  late String _role =
      modelFileRole(widget.model.filename).isHelper ? 'models' : 'helpers';

  @override
  void initState() {
    super.initState();
    final repository = huggingFaceRepository(widget.model.url);
    _load(repository: repository);
  }

  @override
  void dispose() {
    _query.dispose();
    _hf.dispose();
    super.dispose();
  }

  Future<void> _load({String? repository}) async {
    final request = ++_request;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final files = repository == null
          ? <HfGgufFile>[]
          : await ModelHelperService.files(_hf, widget.model, repository);
      final repos = repository == null
          ? await _hf.searchModels(_query.text.trim(),
              limit: 20, images: widget.model.runtime == AiModel.runtimeSd)
          : <HfRepo>[];
      if (!mounted || request != _request) return;
      setState(() {
        _repository = repository;
        _files = files;
        _repos = repos;
      });
    } catch (error) {
      if (mounted && request == _request) setState(() => _error = '$error');
    } finally {
      if (mounted && request == _request) setState(() => _busy = false);
    }
  }

  Future<void> _attach(HfGgufFile file) async {
    final repository = _repository!;
    final accepted = await confirmSheet(context,
        title: 'Attach vision helper?',
        confirmLabel: 'Attach and download',
        message:
            '${file.filename}\n\nThis repository also contains your model file. '
            'Check that its author recommends this projector for your model. '
            'The runtime checks compatibility when you reload.');
    if (accepted != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ModelHelperService.attach(widget.model, repository, _files, file);
      if (mounted)
        Get.snackbar('Helper linked',
            'Check the download in Models, then reload the main model.');
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _attachLocal(AiModel target) async {
    final accepted = await confirmSheet(context,
        title: 'Use this vision helper?',
        confirmLabel: 'Attach',
        message: '${widget.model.filename} → ${target.filename}\n\n'
            'Choose the matching vision model recommended by the file’s author. '
            'The runtime checks compatibility when you reload.');
    if (accepted != true || !mounted) return;
    try {
      await Get.find<ModelController>()
          .attachVisionHelper(target, widget.model.filename, widget.model.url);
      if (mounted)
        Get.snackbar('Helper linked', 'Reload ${target.filename} to use it.');
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<ModelController>();
    final localTargets =
        modelFileRole(widget.model.filename) == ModelFileRole.projector &&
                controller.isDownloaded(widget.model.filename)
            ? controller.availableModels
                .where((m) =>
                    controller.isDownloaded(m.filename) &&
                    m.runtime == AiModel.runtimeLlama &&
                    !modelFileRole(m.filename).isHelper)
                .toList()
            : <AiModel>[];
    final files = _files.where((file) =>
        _role == 'all' ||
        (_role == 'helpers' ? file.role.isHelper : !file.role.isHelper));
    return Scaffold(
      appBar: appScreenBar(context, title: 'Model helpers', showBack: true),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text(widget.model.filename),
        if (widget.model.runtime == AiModel.runtimeSd)
          TextButton.icon(
            icon: const Icon(Icons.layers_outlined),
            label: const Text('Choose image model components'),
            onPressed: () => Get.to(() => Scaffold(
              appBar: appScreenBar(context, title: 'Image model components', showBack: true),
              body: ListView(padding: const EdgeInsets.all(16), children: [
                HfBrowser(images: true, initialQuery: ModelHelperService.searchQuery(widget.model)),
              ]),
            )),
          ),
        if (localTargets.isNotEmpty) ...[
          const SizedBox(height: 12),
          const Text(
              'Attach this downloaded vision helper to its matching model'),
          for (final target in localTargets)
            ListTile(
                title: Text(target.filename),
                trailing: const Icon(Icons.link),
                onTap: _busy ? null : () => _attachLocal(target)),
        ],
        const SizedBox(height: 12),
        Text(modelFileRole(widget.model.filename).isHelper
            ? 'Choose the original repository to find the complete main model for this helper.'
            : 'Choose the original model repository. File roles are inferred from names. Check the author’s architecture, tokenizer and compatibility instructions.'),
        const SizedBox(height: 12),
        TextField(
            controller: _query,
            decoration:
                const InputDecoration(labelText: 'Search model repositories'),
            onSubmitted: (_) => _load()),
        TextButton.icon(
            onPressed: _busy ? null : () => _load(),
            icon: const Icon(Icons.search),
            label: const Text('Search repositories')),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null) ...[
          Text(_error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
          TextButton(
              onPressed: () => _load(repository: _repository),
              child: const Text('Retry')),
        ],
        for (final repo in _repos)
          ListTile(
              title: Text(repo.id),
              subtitle: Text(repo.gated
                  ? 'Requires Hugging Face access'
                  : 'Inspect models and helpers'),
              onTap: _busy ? null : () => _load(repository: repo.id)),
        if (_repository != null) ...[
          TextButton.icon(
              onPressed: () => launchUrl(
                  Uri.https('huggingface.co', '/$_repository'),
                  mode: LaunchMode.externalApplication),
              icon: const Icon(Icons.open_in_new),
              label: Text('Read $_repository instructions')),
          Wrap(spacing: 8, children: [
            for (final entry in const [
              ('all', 'All files'),
              ('models', 'Main models'),
              ('helpers', 'Helpers')
            ])
              ChoiceChip(
                  label: Text(entry.$2),
                  selected: _role == entry.$1,
                  onSelected: (_) => setState(() => _role = entry.$1)),
          ]),
          if (!_busy && files.isEmpty)
            const Padding(
                padding: EdgeInsets.all(16),
                child: Text('No files of this type found in this repository.')),
          for (final file in files)
            Card(
                child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(file.filename,
                            style: Theme.of(context).textTheme.titleSmall),
                        Text(
                            '${file.role.label} · ${DownloadService.formatBytes(file.size)}'),
                        const SizedBox(height: 8),
                        Text(file.role.help),
                        if (ModelHelperService.canAttach(
                            widget.model, _repository!, _files, file))
                          TextButton(
                              onPressed: _busy ? null : () => _attach(file),
                              child: const Text(
                                  'Attach and download vision helper')),
                        if (!file.role.isHelper)
                          TextButton(
                              onPressed: _busy
                                  ? null
                                  : () {
                                      Get.find<ModelController>().downloadModel(
                                          AiModel(
                                              name: file.filename,
                                              filename: file.filename,
                                              url:
                                                  HfService
                                                      .downloadUrl(_repository!,
                                                          file.path),
                                              size:
                                                  DownloadService.formatBytes(
                                                      file.size),
                                              description:
                                                  'Hugging Face · $_repository',
                                              template: widget.model.runtime ==
                                                      AiModel.runtimeSd
                                                  ? 'sd'
                                                  : 'chatml',
                                              runtime: widget.model.runtime));
                                    },
                              child: const Text('Download main model')),
                      ],
                    ))),
        ],
      ]),
    );
  }
}
