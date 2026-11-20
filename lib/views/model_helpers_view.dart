import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:url_launcher/url_launcher.dart';

import '../controllers/model_controller.dart';
import '../core/ui.dart';
import '../models/ai_model.dart';
import '../services/download_service.dart';
import '../services/hf_service.dart';
import '../services/installed_vision_helper.dart';
import '../services/model_artifact_metadata.dart';
import '../services/model_helper_service.dart';
import '../utils/model_file_role.dart';
import '../widgets/model_file_filter.dart';

class ModelCompanionsButton extends StatelessWidget {
  const ModelCompanionsButton({
    super.key,
    required this.model,
    this.kind,
    this.repositoryPath,
  });

  final AiModel model;
  final ModelFileKind? kind;
  final String? repositoryPath;

  @override
  Widget build(BuildContext context) {
    final type = kind ?? model.fileKind;
    if (type == ModelFileKind.unknown) return const SizedBox.shrink();
    return TextButton.icon(
      icon: const Icon(Icons.extension_outlined),
      label: Text(
          type == ModelFileKind.helper ? 'Find main models' : 'Find helpers'),
      onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => ModelHelpersView(
          model: model,
          sourceKind: type,
          repositoryPath: repositoryPath,
        ),
      )),
    );
  }
}

class ModelHelpersView extends StatefulWidget {
  const ModelHelpersView({
    super.key,
    required this.model,
    this.sourceKind,
    this.repositoryPath,
  });
  final AiModel model;
  final ModelFileKind? sourceKind;
  final String? repositoryPath;

  @override
  State<ModelHelpersView> createState() => _ModelHelpersViewState();
}

class _ModelHelpersViewState extends State<ModelHelpersView> {
  final _hf = HfService();
  late final _query =
      TextEditingController(text: ModelHelperService.searchQuery(widget.model));
  List<AiModel> _installed = [];
  VisionHelperSource? _verifiedHelper;
  String? _publishedPath;
  bool _checkingInstalled = true;
  List<HfRepo> _repos = [];
  List<HfGgufFile> _files = [];
  String? _repository;
  String? _error;
  bool _busy = false;
  int _request = 0;
  bool get _isHelper =>
      (widget.sourceKind ?? widget.model.fileKind) == ModelFileKind.helper;
  late ModelFileKind? _kind =
      _isHelper ? ModelFileKind.model : ModelFileKind.helper;

  @override
  void initState() {
    super.initState();
    _identifyCompanions();
  }

  Future<void> _identifyCompanions() async {
    final controller = Get.find<ModelController>();
    final matches = await ModelHelperService.installedCompanions(
      selected: widget.model,
      isHelper: _isHelper,
      installed: controller.availableModels
          .where((model) => controller.isDownloaded(model.filename))
          .toList(),
      identify: controller.identifyInstalledVisionHelper,
    );
    if (!mounted) return;
    setState(() {
      _installed = matches.installed;
      _verifiedHelper = matches.source;
      _checkingInstalled = false;
    });
    if (_request != 0) return;

    final repository = _verifiedHelper?.repository ??
        ModelHelperService.companionRepository(widget.model);
    if (repository != null) {
      await _load(repository: repository);
      return;
    }
    if (_isHelper &&
        _installed.isEmpty &&
        controller.isDownloaded(widget.model.filename)) {
      await _findInInstalledRepositories(controller);
    }
    if (mounted && _request == 0 && _query.text.trim().isNotEmpty) {
      await _load();
    }
  }

  Future<void> _findInInstalledRepositories(ModelController controller) async {
    // Only consult repositories already associated with the user's installed
    // models. The local filename and fingerprint stay on the device.
    final repositories = controller.availableModels
        .where((model) =>
            model.fileKind == ModelFileKind.model &&
            controller.isDownloaded(model.filename))
        .map(ModelHelperService.companionRepository)
        .whereType<String>()
        .toSet()
        .take(4);
    if (repositories.isEmpty) return;
    setState(() => _checkingInstalled = true);
    try {
      final matches = await Future.wait(repositories.map((repository) async {
        try {
          final files = await _hf.listRepositoryFiles(repository);
          final match = await _matchLocalFile(controller, widget.model, files);
          return match == null ? null : (repository: repository, files: files);
        } on Exception {
          return null;
        }
      }));
      if (!mounted || _request != 0) return;
      final match = matches.nonNulls.firstOrNull;
      if (match != null)
        await _load(repository: match.repository, repositoryFiles: match.files);
    } finally {
      if (mounted) setState(() => _checkingInstalled = false);
    }
  }

  Future<HfGgufFile?> _matchLocalFile(
          ModelController controller, AiModel model, List<HfGgufFile> files) =>
      ModelHelperService.matchPublishedFile(
        model: model,
        size: controller.fileSizes[model.filename] ?? 0,
        files: files,
        fingerprint: controller.installedFileFingerprint,
      );

  @override
  void dispose() {
    _query.dispose();
    _hf.dispose();
    super.dispose();
  }

  Future<void> _load(
      {String? repository, List<HfGgufFile>? repositoryFiles}) async {
    repository ??= artifactRepository(_query.text);
    if (repository == null && _query.text.trim().isEmpty) {
      setState(() => _error = 'Enter the model or repository name to search.');
      return;
    }
    final request = ++_request;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final files = repository == null
          ? <HfGgufFile>[]
          : repositoryFiles ?? await _hf.listRepositoryFiles(repository);
      final repos = repository == null
          ? await _hf.searchModels(_query.text.trim(),
              limit: 20, images: widget.model.runtime == AiModel.runtimeSd)
          : <HfRepo>[];
      final controller = Get.find<ModelController>();
      final exact = repository == null
          ? null
          : await _matchLocalFile(controller, widget.model, files);
      final companions = <AiModel>[];
      if (repository != null) {
        final installed = controller.availableModels.where((model) =>
            controller.isDownloaded(model.filename) &&
            !_installed.any((item) => item.filename == model.filename));
        for (final candidate in installed) {
          if (_isHelper &&
              exact != null &&
              candidate.fileKind == ModelFileKind.model &&
              (ModelHelperService.companionRepository(candidate) ==
                      repository ||
                  files.any((file) => file.filename == candidate.filename))) {
            companions.add(candidate);
          } else if (!_isHelper &&
              candidate.fileRole.isHelper &&
              (exact != null ||
                  ModelHelperService.companionRepository(widget.model) ==
                      repository ||
                  files
                      .any((file) => file.filename == widget.model.filename)) &&
              await _matchLocalFile(controller, candidate, files) != null) {
            companions.add(candidate);
          }
        }
      }
      if (!mounted || request != _request) return;
      setState(() {
        _repository = repository;
        _publishedPath = exact?.path;
        _installed = [..._installed, ...companions];
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
      await ModelHelperService.attach(widget.model, repository, _files, file,
          verifiedModelPath: _publishedPath);
      if (mounted) await _identifyCompanions();
      if (mounted)
        Get.snackbar('Helper linked',
            'Check the download in Models, then reload the main model.');
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _attachLocal(AiModel target, AiModel helper) async {
    final accepted = await confirmSheet(context,
        title: 'Use this vision helper?',
        confirmLabel: 'Attach',
        message: '${helper.filename} → ${target.filename}\n\n'
            'Choose the matching vision model recommended by the file’s author. '
            'The runtime checks compatibility when you reload.');
    if (accepted != true || !mounted) return;
    try {
      await Get.find<ModelController>()
          .attachVisionHelper(target, helper.filename, helper.url);
      if (mounted)
        Get.snackbar('Helper linked', 'Reload ${target.filename} to use it.');
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _downloadMain(HfGgufFile file, {required bool pair}) async {
    final repository = _repository!;
    final controller = Get.find<ModelController>();
    final model = AiModel(
      name: file.filename,
      filename: file.filename,
      url: HfService.downloadUrl(repository, file.path),
      size: DownloadService.formatBytes(file.size),
      description: 'Hugging Face · $repository',
      template: widget.model.runtime == AiModel.runtimeSd ? 'sd' : 'chatml',
      runtime: widget.model.runtime,
    );
    if (pair) {
      final accepted = await confirmSheet(context,
          title: 'Download and pair?',
          message:
              'Check that the author lists ${widget.model.filename} as the vision helper for ${file.filename}.',
          confirmLabel: 'Download and pair');
      if (accepted != true || !mounted) return;
    }
    setState(() => _busy = true);
    try {
      if (pair) {
        await controller.attachVisionHelper(
            model, widget.model.filename, widget.model.url);
      }
      await controller.downloadModel(model);
      if (mounted) await _identifyCompanions();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<ModelController>();
    final isHelper = _isHelper;
    final currentInstalled = controller.isDownloaded(widget.model.filename);
    final selectable = _installed.isNotEmpty ||
            _checkingInstalled ||
            !currentInstalled ||
            (_isHelper
                ? widget.model.fileRole != ModelFileRole.projector
                : widget.model.runtime != AiModel.runtimeLlama)
        ? const <AiModel>[]
        : controller.availableModels
            .where((candidate) =>
                controller.isDownloaded(candidate.filename) &&
                (_isHelper
                    ? candidate.fileKind == ModelFileKind.model &&
                        candidate.runtime == AiModel.runtimeLlama &&
                        candidate.filename.toLowerCase().endsWith('.gguf')
                    : candidate.fileRole == ModelFileRole.projector))
            .toList();
    final verifiedPath = _verifiedHelper?.repository == _repository
        ? _verifiedHelper?.path
        : null;
    final sourcePath = _publishedPath ?? verifiedPath ?? widget.repositoryPath;
    final repositoryHasCurrentFile = _files.any((file) => sourcePath == null
        ? file.filename == widget.model.filename
        : file.path == sourcePath);
    final images = widget.model.runtime == AiModel.runtimeSd;
    final files = _files.where((file) {
      final sourceFile = (_publishedPath ?? verifiedPath) == file.path ||
          (_repository == huggingFaceRepository(widget.model.url) &&
              widget.repositoryPath == file.path);
      return !sourceFile &&
          (_kind == null || file.kindInRepository(images: images) == _kind);
    });
    return Scaffold(
      appBar: appScreenBar(context,
          title: isHelper ? 'Find main models' : 'Find helpers',
          showBack: true),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text(widget.model.filename),
        if (_installed.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(isHelper
              ? 'Possible installed main models'
              : 'Possible installed helpers'),
          for (final candidate in _installed)
            ListTile(
                title: Text(candidate.filename),
                subtitle: Text(candidate.fileKind.label),
                trailing: (isHelper ? widget.model : candidate).fileRole ==
                        ModelFileRole.projector
                    ? const Icon(Icons.link)
                    : null,
                onTap: _busy ||
                        (isHelper ? widget.model : candidate).fileRole !=
                            ModelFileRole.projector
                    ? null
                    : () => isHelper
                        ? _attachLocal(candidate, widget.model)
                        : _attachLocal(widget.model, candidate)),
        ],
        if (selectable.isNotEmpty)
          ExpansionTile(
            title: Text(isHelper
                ? 'Choose an installed vision model'
                : 'Choose an installed vision helper'),
            subtitle:
                const Text('Confirm compatibility with the publisher first'),
            children: [
              for (final candidate in selectable)
                ListTile(
                  title: Text(candidate.filename),
                  onTap: _busy
                      ? null
                      : () => _isHelper
                          ? _attachLocal(candidate, widget.model)
                          : _attachLocal(widget.model, candidate),
                ),
            ],
          ),
        const SizedBox(height: 12),
        Text(isHelper
            ? 'Compare the main models listed with this helper. Check the repository instructions for the matching model.'
            : 'See the helpers listed with this model. Check the repository instructions for compatible versions.'),
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
        if (_query.text.trim().isEmpty &&
            _repository == null &&
            !_busy &&
            !_checkingInstalled &&
            _verifiedHelper == null &&
            _installed.isEmpty)
          const Text(
              'This file has no identifiable companion. Enter the model name or publisher repository.'),
        if (_busy || _checkingInstalled) const LinearProgressIndicator(),
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
          ModelFileFilter(
              selected: _kind,
              onChanged: (kind) => setState(() => _kind = kind)),
          if (!repositoryHasCurrentFile && !_busy)
            const Text(
                'This repository does not list your exact file. Check its model card for compatibility.'),
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
                            '${file.kindInRepository(images: images).label} · ${DownloadService.formatBytes(file.size)}'),
                        const SizedBox(height: 8),
                        Text(file.kindInRepository(images: images) ==
                                ModelFileKind.unknown
                            ? 'The file type could not be identified.'
                            : file.role.help),
                        if (!isHelper &&
                            currentInstalled &&
                            ModelHelperService.canAttach(
                                widget.model, _repository!, _files, file,
                                verifiedModelPath: _publishedPath))
                          TextButton(
                              onPressed: _busy ? null : () => _attach(file),
                              child: const Text(
                                  'Attach and download vision helper')),
                        if (file.kindInRepository(images: images) ==
                                ModelFileKind.model &&
                            HfService.canDownloadSingleFile(file,
                                images: images)) ...[
                          if (controller.isDownloaded(file.filename))
                            const Text('Installed')
                          else
                            TextButton(
                              onPressed: _busy
                                  ? null
                                  : () => _downloadMain(file, pair: false),
                              child: const Text('Download main model'),
                            ),
                          if (repositoryHasCurrentFile &&
                              !controller.isDownloaded(file.filename) &&
                              file.role == ModelFileRole.model &&
                              widget.model.fileRole ==
                                  ModelFileRole.projector &&
                              controller.isDownloaded(widget.model.filename))
                            TextButton(
                              onPressed: _busy
                                  ? null
                                  : () => _downloadMain(file, pair: true),
                              child: const Text(
                                  'Download and pair with this helper'),
                            ),
                        ],
                      ],
                    ))),
        ],
      ]),
    );
  }
}
