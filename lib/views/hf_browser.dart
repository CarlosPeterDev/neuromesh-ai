import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/model_controller.dart';
import '../controllers/settings_controller.dart';
import '../core/ui.dart';
import '../models/ai_model.dart';
import '../services/download_service.dart';
import '../services/favorites_service.dart';
import '../services/hf_service.dart';
import '../utils/image_bundle.dart';
import '../utils/model_fit.dart';
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
  final String initialQuery;
  const HfBrowser({super.key, this.images = false, this.initialQuery = ''});

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
  bool _fitsOnly = false;
  bool _onlyFav = false;
  bool _exhausted = false;
  String _task = 'any'; // any | text | vision | embedding
  String _quant = 'any'; // any | Q4 | Q5 | Q6 | Q8 | other (applies to files)
  String _sort = 'downloads';
  String _size = 'any'; // any | s | m | l | xl
  ScrollPosition? _scrollPos;

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

  /// This phone's memory plus connected cluster workers.
  double get _ram => availableMemoryGB();

  FavoritesService? get _favs =>
      Get.isRegistered<FavoritesService>() ? Get.find<FavoritesService>() : null;

  int get _activeFilters =>
      (_size != 'any' ? 1 : 0) +
      (_task != 'any' ? 1 : 0) +
      (_quant != 'any' ? 1 : 0) +
      (_sort != 'downloads' ? 1 : 0) +
      (_fitsOnly ? 1 : 0) +
      (_onlyFav ? 1 : 0);

  void _applyFilters() {
    _limit = 30;
    _exhausted = false;
    _run();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Infinite scroll: watch the scrollable this browser sits in.
    final pos = Scrollable.maybeOf(context)?.position;
    if (pos != _scrollPos) {
      _scrollPos?.removeListener(_onScroll);
      _scrollPos = pos;
      _scrollPos?.addListener(_onScroll);
    }
  }

  void _onScroll() {
    final pos = _scrollPos;
    if (pos == null || !pos.hasPixels) return;
    if (pos.extentAfter < 600) _loadMore();
  }

  void _loadMore() {
    if (_loading || _exhausted || _repos.isEmpty || _rawCount < _limit) return;
    _limit += 30;
    _run(more: true);
  }

  @override
  void initState() {
    super.initState();
    _query = widget.initialQuery;
    _search.text = _query;
    _run();
  }

  @override
  void dispose() {
    _scrollPos?.removeListener(_onScroll);
    _debounce?.cancel();
    _search.dispose();
    _hf.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () {
      _query = value.trim();
      _applyFilters();
    });
  }

  Future<void> _run({bool more = false}) async {
    final seq = ++_seq;
    final before = _rawCount;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repos = await _hf.searchModels(_query,
          limit: (_size != 'any' || _fitsOnly || _onlyFav) ? _limit * 2 : _limit,
          images: widget.images,
          task: _task == 'any' ? null : _task,
          sort: _sort);
      if (!mounted || seq != _seq) return;
      setState(() {
        _repos = repos;
        _rawCount = repos.length;
        // A bigger request that returned nothing new means the end.
        if (more && repos.length <= before) _exhausted = true;
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
      if (_fitsOnly) {
        out = out.where((r) {
          final need = r.estimatedRamGB;
          if (need == null) return false;
          final f = fitFor(need, _ram);
          return f == ModelFit.recommended || f == ModelFit.fits;
        });
      }
    }
    if (_onlyFav) {
      final favs = _favs;
      out = out.where((r) => favs?.isFav(FavoritesService.hfKey(r.id)) ?? false);
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

  Widget _choices(
    String title,
    Map<String, String> options,
    String current,
    void Function(String) onPick,
  ) {
    final t = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6, left: 2),
          child: Text(title, style: t.small),
        ),
        Wrap(spacing: 8, runSpacing: 6, children: [
          for (final e in options.entries)
            ChoiceChip(
              label: Text(e.value),
              selected: current == e.key,
              visualDensity: VisualDensity.compact,
              onSelected: (_) => onPick(e.key),
            ),
        ]),
      ]),
    );
  }

  Future<void> _openFilters() async {
    await showAppSheet<void>(context, title: 'Filters', builder: (ctx) {
      return StatefulBuilder(builder: (ctx, setSheet) {
        void change(VoidCallback f, {bool refetch = true}) {
          setState(f);
          setSheet(() {});
          if (refetch) _applyFilters();
        }

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _choices('Sort by', const {
              'downloads': 'Most downloaded',
              'likes': 'Most liked',
              'trendingScore': 'Trending',
              'lastModified': 'Newest',
            }, _sort, (v) => change(() => _sort = v)),
            if (!widget.images) ...[
              _choices('Size', _sizes, _size, (v) => change(() => _size = v)),
              _choices('Type', const {
                'any': 'Any',
                'text': 'Text',
                'vision': 'Vision',
                'embedding': 'Embedding',
              }, _task, (v) => change(() => _task = v)),
              _choices('Quantisation (applies to files inside a model)', const {
                'any': 'Any',
                'Q4': 'Q4',
                'Q5': 'Q5',
                'Q6': 'Q6',
                'Q8': 'Q8',
                'other': 'Other',
              }, _quant, (v) => change(() => _quant = v, refetch: false)),
              Wrap(spacing: 8, runSpacing: 6, children: [
                FilterChip(
                  avatar: const Icon(Icons.smartphone_rounded, size: 16),
                  label: const Text('Fits my device / cluster'),
                  selected: _fitsOnly,
                  onSelected: (v) => change(() => _fitsOnly = v),
                ),
                FilterChip(
                  avatar: const Icon(Icons.star_rounded, size: 16),
                  label: const Text('Only favorites'),
                  selected: _onlyFav,
                  onSelected: (v) => change(() => _onlyFav = v, refetch: false),
                ),
              ]),
            ],
            const SizedBox(height: 12),
            TonalButton.neutral(
              ctx,
              label: 'Reset filters',
              onTap: () {
                setState(() {
                  _sort = 'downloads';
                  _size = 'any';
                  _task = 'any';
                  _quant = 'any';
                  _fitsOnly = false;
                  _onlyFav = false;
                });
                Navigator.pop(ctx);
                _applyFilters();
              },
            ),
          ],
        );
      });
    });
  }

  void _openRepo(HfRepo repo) {
    showAppSheet<void>(
      context,
      title: repo.name,
      subtitle: repo.id,
      builder: (ctx) => _RepoFiles(
          repo: repo, hf: _hf, images: widget.images, quant: _quant),
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
            _applyFilters();
          },
          decoration: appInputDecoration(
            context,
            hint: widget.images
                ? 'Search image models, e.g. sd-turbo'
                : 'Search Hugging Face, e.g. deepseek',
            prefix: const Icon(Icons.search_rounded),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 38,
          child: ListView(scrollDirection: Axis.horizontal, children: [
            _chip(
                icon: Icons.tune_rounded,
                label: _activeFilters > 0 ? 'Filters · $_activeFilters' : 'Filters',
                selected: _activeFilters > 0,
                onTap: _openFilters),
            if (!widget.images) ...[
              _chip(
                  icon: Icons.star_rounded,
                  label: 'Favorites',
                  selected: _onlyFav,
                  onTap: () {
                    setState(() => _onlyFav = !_onlyFav);
                    _applyFilters();
                  }),
              _chip(
                  icon: Icons.visibility_outlined,
                  label: 'Vision',
                  selected: _task == 'vision',
                  onTap: () {
                    setState(() => _task = _task == 'vision' ? 'any' : 'vision');
                    _applyFilters();
                  }),
              _chip(
                  icon: Icons.smartphone_rounded,
                  label: 'Fits my device',
                  selected: _fitsOnly,
                  onTap: () {
                    setState(() => _fitsOnly = !_fitsOnly);
                    _applyFilters();
                  }),
            ],
          ]),
        ),
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
                    '${r.author}${r.paramsB != null ? ' · ${r.paramsB! < 1 ? '${(r.paramsB! * 1000).round()}M' : '${r.paramsB!.toStringAsFixed(r.paramsB! < 10 ? 1 : 0)}B'}' : ''} · ${_compact(r.downloads)} downloads${r.isVision ? ' · vision' : ''}${r.gated ? ' · login required' : ''}${!r.supported ? ' · unsupported (${r.architecture})' : ''}',
                trailing: Obx(() {
                  final fav = _favs?.isFav(FavoritesService.hfKey(r.id)) ?? false;
                  return Row(mainAxisSize: MainAxisSize.min, children: [
                    if (r.estimatedRamGB != null)
                      FitBadge(fitFor(r.estimatedRamGB!, _ram)),
                    InkWell(
                      onTap: () => _favs?.toggle(FavoritesService.hfKey(r.id)),
                      borderRadius: BorderRadius.circular(20),
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Icon(
                            fav ? Icons.star_rounded : Icons.star_border_rounded,
                            size: 22,
                            color: fav ? const Color(0xFFE0A800) : null),
                      ),
                    ),
                  ]);
                }),
                chevron: true,
                onTap: () => _openRepo(r),
              ),
          ]),
          if (_rawCount >= _limit && !_exhausted)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: _loading
                  ? const Center(
                      child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2)))
                  : TextButton(
                      onPressed: _loadMore,
                      child: const Text('Load more'),
                    ),
            ),
        ],
      ],
    );
  }
}

class _RepoFiles extends StatefulWidget {
  final HfRepo repo;
  final HfService hf;
  final bool images;
  final String quant;
  const _RepoFiles(
      {required this.repo, required this.hf, this.images = false, this.quant = 'any'});

  @override
  State<_RepoFiles> createState() => _RepoFilesState();
}

class _RepoFilesState extends State<_RepoFiles> {
  late final Future<List<HfGgufFile>> _files;
  String _role = 'models';

  @override
  void initState() {
    super.initState();
    _files = widget.hf.listGgufFiles(widget.repo.id, images: widget.images, includeHelpers: true);
  }

  AiModel _asModel(HfGgufFile f) => AiModel(
        name: f.role.isHelper ? f.filename : widget.repo.name,
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
          Text(f.role.help),
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
        final offered = snap.data ?? const <HfGgufFile>[];
        final all = widget.images || _role == 'all'
            ? offered
            : offered.where((f) => _role == 'helpers'
                ? f.role.isHelper : !f.role.isHelper).toList();
        final filtered = (widget.images || widget.quant == 'any')
            ? all
            : all.where((f) => _quantMatches(f.quant, widget.quant)).toList();
        // A quant filter that matches nothing shows everything instead.
        final files = filtered.isEmpty ? all : filtered;
        if (files.isEmpty && widget.images) {
          return _BundlePicker(repo: widget.repo, hf: widget.hf);
        }
        if (files.isEmpty && offered.isEmpty) {
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
        return Obx(() => Column(children: [
            if (!widget.images)
              Wrap(spacing: 8, children: [
                for (final entry in const [('all', 'All'), ('models', 'Main models'), ('helpers', 'Helpers')])
                  ChoiceChip(label: Text(entry.$2), selected: _role == entry.$1,
                      onSelected: (_) => setState(() => _role = entry.$1)),
              ]),
            if (files.isEmpty) const Padding(padding: EdgeInsets.all(12),
                child: Text('No files match this filter.')),
            AppGroup(children: [
              for (final f in files)
                AppRow(
                  icon: Icons.insert_drive_file_outlined,
                  title: f.role.isHelper ? f.role.label : f.quant.isEmpty ? f.filename : f.quant,
                  subtitle:
                      '${DownloadService.formatBytes(f.size)} · ${f.filename}'
                      '${widget.images || f.role.isHelper ? '' : '\nEst. RAM at ${Get.find<SettingsController>().contextSize.value} tokens: ${(needGBForBytes(f.size) + contextHeadroomGB(needGBForBytes(f.size))).toStringAsFixed(1)} GiB'}',
                  trailing: controller.downloadedFiles.contains(f.filename)
                      ? Text('On phone', style: t.small)
                      : controller.isDownloadingModel(f.filename)
                          ? Text('Downloading', style: t.small)
                          : f.role.isHelper ? const Icon(Icons.extension_outlined)
                          : FitBadge(fitFor(needGBForBytes(f.size))),
                  chevron: !controller.downloadedFiles.contains(f.filename),
                  onTap: controller.downloadedFiles.contains(f.filename) ||
                          controller.isDownloadingModel(f.filename)
                      ? null
                      : () => _choose(f),
                ),
            ]),
            if (widget.images) ...[
              const SizedBox(height: 12),
              _BundlePicker(repo: widget.repo, hf: widget.hf, compact: true),
            ],
          ]));
      },
    );
  }
}

/// Whether a file's quant label ("Q4_K_M", "IQ4_XS") belongs to bucket
/// [bucket]: Q4, Q5, Q6, Q8, or other (F16, Q2, Q3…).
bool _quantMatches(String quant, String bucket) {
  final q = quant.toUpperCase();
  const known = ['Q4', 'Q5', 'Q6', 'Q8'];
  if (bucket == 'other') return !known.any(q.contains);
  return q.contains(bucket);
}

/// Multi-file image models (Flux, Z-Image, SD3…): choose the parts, download
/// them into one folder, and the app loads them together.
class _BundlePicker extends StatefulWidget {
  final HfRepo repo;
  final HfService hf;
  final bool compact;
  const _BundlePicker({required this.repo, required this.hf, this.compact = false});

  @override
  State<_BundlePicker> createState() => _BundlePickerState();
}

class _BundlePickerState extends State<_BundlePicker> {
  late final Future<List<HfGgufFile>> _parts = widget.hf.listImageParts(widget.repo.id);
  Set<String>? _selected;

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return FutureBuilder<List<HfGgufFile>>(
      future: _parts,
      builder: (ctx, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return widget.compact
              ? const SizedBox.shrink()
              : const Padding(
                  padding: EdgeInsets.symmetric(vertical: 32),
                  child: Center(child: CircularProgressIndicator()));
        }
        final parts = (snap.data ?? const <HfGgufFile>[])
            .where((f) => roleOfFile(f.path) != BundleRole.other)
            .toList();
        if (parts.isEmpty) {
          return widget.compact
              ? const SizedBox.shrink()
              : const EmptyState(
                  icon: Icons.search_off_rounded,
                  title: 'No loadable files here',
                  message:
                      'This repository has no .safetensors or .gguf weights the app can use.');
        }
        final sizes = {for (final f in parts) f.path: f.size};
        _selected ??= recommendBundle(sizes, familyHint: widget.repo.name).toSet();
        final sel = _selected!;
        final total = parts.where((f) => sel.contains(f.path)).fold<int>(0, (a, f) => a + f.size);
        final b = resolveBundle(sel.toList(), sizes: sizes);
        final ok = b.isValid;
        parts.sort((a, b) =>
            roleOfFile(a.path).index.compareTo(roleOfFile(b.path).index));
        const roleName = {
          BundleRole.diffusion: 'Diffusion model',
          BundleRole.checkpoint: 'Full model',
          BundleRole.vae: 'VAE',
          BundleRole.clipL: 'CLIP-L',
          BundleRole.clipG: 'CLIP-G',
          BundleRole.t5xxl: 'T5 text encoder',
          BundleRole.llm: 'Language text encoder',
        };
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
            child: Text('Multi-file model: pick the parts (recommended ones are ticked)',
                style: t.small),
          ),
          AppGroup(children: [
            for (final f in parts)
              CheckboxListTile(
                dense: true,
                value: sel.contains(f.path),
                onChanged: (v) => setState(() => v == true ? sel.add(f.path) : sel.remove(f.path)),
                title: Text(f.path, style: const TextStyle(fontSize: 13)),
                subtitle: Text(
                    '${roleName[roleOfFile(f.path)] ?? ''} · ${DownloadService.formatBytes(f.size)}',
                    style: const TextStyle(fontSize: 11.5)),
              ),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: Text('Total: ${DownloadService.formatBytes(total)}')),
            FitBadge(fitFor(needGBForBytes(total))),
          ]),
          const SizedBox(height: 8),
          PrimaryButton(
            label: ok ? 'Download these parts as one model' : 'Select a diffusion or full model file',
            onPressed: !ok
                ? null
                : () {
                    final chosen = parts.where((f) => sel.contains(f.path)).toList();
                    final used = <String>{};
                    final files = <({String url, String file, int size})>[];
                    for (final f in chosen) {
                      var n = f.filename;
                      if (!used.add(n)) n = '${used.length}_$n';
                      files.add((url: HfService.downloadUrl(widget.repo.id, f.path), file: n, size: f.size));
                    }
                    Get.find<ModelController>().downloadImageBundle(widget.repo.name, files);
                    Navigator.of(context).maybePop();
                  },
          ),
        ]);
      },
    );
  }
}
