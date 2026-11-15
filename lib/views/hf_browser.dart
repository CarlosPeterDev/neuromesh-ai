import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/model_controller.dart';
import '../core/ui.dart';
import '../models/ai_model.dart';
import '../services/download_service.dart';
import '../services/device_info_service.dart';
import '../services/hf_service.dart';
import '../services/download_queue.dart';

String _compact(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
  return '$n';
}

/// Search Hugging Face for GGUF models and download them. Replaces the old
/// fixed list of download links.
class HfBrowser extends StatefulWidget {
  /// True to search image (Stable Diffusion) models instead of GGUF chat models.
  final bool images;
  const HfBrowser({super.key, this.images = false});

  @override
  State<HfBrowser> createState() => _HfBrowserState();
}

class _HfBrowserState extends State<HfBrowser> {
  final _hf = HfService();
  final _search = TextEditingController();
  Timer? _debounce;
  List<HfRepo> _repos = const [];
  bool _loading = false;
  String? _error;
  String _query = '';
  int _limit = 30;
  int _seq = 0;
  int _rawCount = 0;
  bool _showUnsupported = false;
  bool _vision = false;
  bool _fitsOnly = false;
  String _sort = 'downloads';
  String _size = 'any'; // any | s | m | l | xl

  static const _sizes = {
    'any': 'Any size',
    's': 'Under 1B',
    'm': '1–3B',
    'l': '3–8B',
    'xl': '8B+',
  };

  bool _sizeOk(HfRepo r) {
    if (_size == 'any') return true;
    final b = r.paramsB;
    if (b == null) return false;
    return switch (_size) {
      's' => b < 1,
      'm' => b >= 1 && b < 3,
      'l' => b >= 3 && b < 8,
      _ => b >= 8,
    };
  }

  double get _ram => Get.isRegistered<DeviceInfoService>()
      ? Get.find<DeviceInfoService>().totalRamGB.value
      : 0;

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _hf.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () {
      _query = value.trim();
      _limit = 30;
      _run();
    });
  }

  Future<void> _run() async {
    final seq = ++_seq;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repos = await _hf.searchModels(_query,
          limit: (_size != 'any' || _fitsOnly) ? _limit * 2 : _limit,
          images: widget.images,
          vision: _vision,
          sort: _sort);
      if (!mounted || seq != _seq) return;
      setState(() {
        _repos = repos;
        _rawCount = repos.length;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Iterable<HfRepo> get _visible {
    Iterable<HfRepo> out = _repos;
    if (!widget.images) {
      if (!_showUnsupported) out = out.where((r) => r.supported);
      out = out.where(_sizeOk);
      if (_fitsOnly) out = out.where((r) => r.fitsPhone(_ram) != false && r.paramsB != null);
    }
    return out;
  }

  int get _hiddenCount =>
      widget.images ? 0 : _repos.where((r) => !r.supported).length;

  Widget _chip(
          {required IconData icon,
          required String label,
          required bool selected,
          required VoidCallback onTap}) =>
      Padding(
        padding: const EdgeInsets.only(right: 8),
        child: FilterChip(
          avatar: Icon(icon, size: 16),
          label: Text(label),
          selected: selected,
          onSelected: (_) => onTap(),
          visualDensity: VisualDensity.compact,
        ),
      );

  Future<void> _pickSort() async {
    final v = await showAppSheet<String>(context, title: 'Sort by', builder: (ctx) {
      return AppGroup(children: [
        for (final e in const {
          'downloads': 'Most downloaded',
          'likes': 'Most liked',
          'trendingScore': 'Trending',
          'lastModified': 'Newest',
        }.entries)
          AppRow(
              title: e.value,
              selected: _sort == e.key,
              onTap: () => Navigator.pop(ctx, e.key)),
      ]);
    });
    if (v != null && v != _sort) {
      setState(() => _sort = v);
      _run();
    }
  }

  Future<void> _pickSize() async {
    final v = await showAppSheet<String>(context, title: 'Model size', builder: (ctx) {
      return AppGroup(children: [
        for (final e in _sizes.entries)
          AppRow(
              title: e.value,
              selected: _size == e.key,
              onTap: () => Navigator.pop(ctx, e.key)),
      ]);
    });
    if (v != null && v != _size) {
      setState(() => _size = v);
      _run();
    }
  }

  void _openRepo(HfRepo repo) {
    showAppSheet<void>(
      context,
      title: repo.name,
      subtitle: repo.id,
      builder: (ctx) => _RepoFiles(repo: repo, hf: _hf, images: widget.images),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _search,
          onChanged: _onChanged,
          textInputAction: TextInputAction.search,
          onSubmitted: (v) {
            _debounce?.cancel();
            _query = v.trim();
            _limit = 30;
            _run();
          },
          decoration: appInputDecoration(
            context,
            hint: widget.images
                ? 'Search image models, e.g. sd-turbo'
                : 'Search Hugging Face, e.g. deepseek',
            prefix: const Icon(Icons.search_rounded),
          ),
        ),
        if (!widget.images) ...[
          const SizedBox(height: 8),
          SizedBox(
            height: 38,
            child: ListView(scrollDirection: Axis.horizontal, children: [
              _chip(
                  icon: Icons.sort_rounded,
                  label: switch (_sort) {
                    'likes' => 'Most liked',
                    'lastModified' => 'Newest',
                    'trendingScore' => 'Trending',
                    _ => 'Most downloaded',
                  },
                  selected: false,
                  onTap: _pickSort),
              _chip(
                  icon: Icons.photo_size_select_large_rounded,
                  label: _sizes[_size]!,
                  selected: _size != 'any',
                  onTap: _pickSize),
              _chip(
                  icon: Icons.visibility_outlined,
                  label: 'Vision',
                  selected: _vision,
                  onTap: () {
                    setState(() => _vision = !_vision);
                    _run();
                  }),
              _chip(
                  icon: Icons.smartphone_rounded,
                  label: 'Fits my phone',
                  selected: _fitsOnly,
                  onTap: () {
                    setState(() => _fitsOnly = !_fitsOnly);
                    _run();
                  }),
            ]),
          ),
        ],
        const SizedBox(height: 10),
        Text(
          _query.isEmpty
              ? (widget.images ? 'Most downloaded image models' : 'Most downloaded GGUF models')
              : '${widget.images ? 'Image' : 'GGUF'} models matching "$_query"',
          style: t.small,
        ),
        const SizedBox(height: 8),
        if (_loading && _repos.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 40),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_error != null && _repos.isEmpty)
          EmptyState(
            icon: Icons.cloud_off_rounded,
            title: 'Could not load models',
            message: _error,
            action: TextButton(onPressed: _run, child: const Text('Try again')),
          )
        else if (_repos.isEmpty)
          const EmptyState(
            icon: Icons.search_off_rounded,
            title: 'No GGUF models found',
            message: 'Try a different search.',
          )
        else ...[
          if (!widget.images && _hiddenCount > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(children: [
                Expanded(
                  child: Text(
                    _showUnsupported
                        ? 'Showing $_hiddenCount model${_hiddenCount == 1 ? '' : 's'} this app can\'t run (marked)'
                        : '$_hiddenCount model${_hiddenCount == 1 ? '' : 's'} hidden: unsupported architecture',
                    style: t.small,
                  ),
                ),
                TextButton(
                  onPressed: () =>
                      setState(() => _showUnsupported = !_showUnsupported),
                  child: Text(_showUnsupported ? 'Hide' : 'Show anyway'),
                ),
              ]),
            ),
          AppGroup(children: [
            for (final r in _visible)
              AppRow(
                icon: !r.supported
                    ? Icons.block_rounded
                    : r.gated
                        ? Icons.lock_outline_rounded
                        : Icons.memory_rounded,
                title: r.name,
                subtitle:
                    '${r.author}${r.paramsB != null ? ' · ${r.paramsB! < 1 ? '${(r.paramsB! * 1000).round()}M' : '${r.paramsB!.toStringAsFixed(r.paramsB! < 10 ? 1 : 0)}B'}' : ''} · ${_compact(r.downloads)} downloads${r.isVision ? ' · vision' : ''}${r.fitsPhone(_ram) == true ? ' · fits your phone' : (r.fitsPhone(_ram) == false ? ' · may be too big' : '')}${r.gated ? ' · login required' : ''}${!r.supported ? ' · unsupported (${r.architecture})' : ''}',
                chevron: true,
                onTap: () => _openRepo(r),
              ),
          ]),
          if (_rawCount >= _limit)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: TextButton(
                onPressed: _loading
                    ? null
                    : () {
                        _limit += 30;
                        _run();
                      },
                child: Text(_loading ? 'Loading…' : 'Load more'),
              ),
            ),
        ],
      ],
    );
  }
}

/// "Fits" label for a model file of [bytes] on this phone's RAM.
String _fit(int bytes) {
  if (!Get.isRegistered<DeviceInfoService>()) return '';
  final ram = Get.find<DeviceInfoService>().totalRamGB.value;
  if (ram <= 0 || bytes <= 0) return '';
  final needGB = bytes / 1073741824 * 1.15 + 0.5;
  if (needGB <= ram * 0.45) return 'runs well · ';
  if (needGB <= ram * 0.6) return 'fits · ';
  return 'too big for this phone · ';
}

class _RepoFiles extends StatefulWidget {
  final HfRepo repo;
  final HfService hf;
  final bool images;
  const _RepoFiles({required this.repo, required this.hf, this.images = false});

  @override
  State<_RepoFiles> createState() => _RepoFilesState();
}

class _RepoFilesState extends State<_RepoFiles> {
  late final Future<List<HfGgufFile>> _files;

  @override
  void initState() {
    super.initState();
    _files = widget.hf.listGgufFiles(widget.repo.id, images: widget.images);
  }

  AiModel _asModel(HfGgufFile f) => AiModel(
        name: widget.repo.name,
        filename: f.filename,
        url: HfService.downloadUrl(widget.repo.id, f.path),
        size: DownloadService.formatBytes(f.size),
        description: 'Hugging Face · ${widget.repo.id}',
        template: widget.images ? 'sd' : 'chatml',
        runtime: widget.images ? AiModel.runtimeSd : null,
      );

  void _choose(HfGgufFile f) {
    final model = _asModel(f);
    final controller = Get.find<ModelController>();
    showAppSheet<void>(
      context,
      title: f.quant.isEmpty ? f.filename : '${widget.repo.name} · ${f.quant}',
      subtitle: f.filename,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppRow(
            icon: Icons.sd_storage_outlined,
            title: 'File size',
            trailing: Text(DownloadService.formatBytes(f.size)),
          ),
          const SizedBox(height: 12),
          AppNotice(
            widget.images
                ? 'Image models are 1-5 GB. Small models (SD 1.5, SD-Turbo, SDXS) run best on phones; large SDXL/Flux files may not load. Some repos only work on a PC.'
                : 'Large download. Wi-Fi is recommended. Models bigger than your phone\'s free memory will not load.',
            icon: Icons.wifi_rounded,
          ),
          const SizedBox(height: 20),
          PrimaryButton(
            label: 'Download into the app',
            onPressed: () {
              Navigator.of(ctx).pop();
              Navigator.of(context).maybePop();
              controller.downloadModel(model);
            },
          ),
          const SizedBox(height: 10),
          TonalButton.neutral(
            ctx,
            label: 'Add to download queue',
            onTap: () {
              Navigator.of(ctx).pop();
              Navigator.of(context).maybePop();
              Get.find<DownloadQueue>().add(model);
              Get.snackbar('Queued', model.name,
                  snackPosition: SnackPosition.BOTTOM);
            },
          ),
          const SizedBox(height: 10),
          TonalButton.neutral(
            ctx,
            label: 'Save to phone Downloads folder instead',
            onTap: () {
              Navigator.of(ctx).pop();
              Navigator.of(context).maybePop();
              controller.downloadModelToDownloads(model);
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    if (widget.repo.gated) {
      return const AppNotice(
        'This model needs a Hugging Face login and licence acceptance, so it cannot be downloaded here.',
        icon: Icons.lock_outline_rounded,
      );
    }
    return FutureBuilder<List<HfGgufFile>>(
      future: _files,
      builder: (ctx, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 32),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (snap.hasError) {
          return EmptyState(
            icon: Icons.cloud_off_rounded,
            title: 'Could not load files',
            message: snap.error.toString(),
          );
        }
        final files = snap.data ?? const <HfGgufFile>[];
        if (files.isEmpty) {
          return EmptyState(
            icon: Icons.search_off_rounded,
            title: widget.images
                ? 'No single-file image models here'
                : 'No single-file GGUF models here',
            message: widget.images
                ? 'This repository uses a multi-folder layout the app cannot load.'
                : 'This repository only has split or projector files.',
          );
        }
        final controller = Get.find<ModelController>();
        return Obx(() => AppGroup(children: [
              for (final f in files)
                AppRow(
                  icon: Icons.insert_drive_file_outlined,
                  title: f.quant.isEmpty ? f.filename : f.quant,
                  subtitle:
                      '${DownloadService.formatBytes(f.size)} · ${_fit(f.size)}${f.filename}',
                  trailing: controller.downloadedFiles.contains(f.filename)
                      ? Text('On phone', style: t.small)
                      : controller.isDownloadingModel(f.filename)
                          ? Text('Downloading', style: t.small)
                          : null,
                  chevron: !controller.downloadedFiles.contains(f.filename),
                  onTap: controller.downloadedFiles.contains(f.filename) ||
                          controller.isDownloadingModel(f.filename)
                      ? null
                      : () => _choose(f),
                ),
            ]));
      },
    );
  }
}
